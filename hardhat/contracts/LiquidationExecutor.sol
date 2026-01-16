// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {SafeERC20, IERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

interface IPool {
  function flashLoanSimple(
    address receiverAddress,
    address asset,
    uint256 amount,
    bytes calldata params,
    uint16 referralCode
  ) external;
}

interface IFlashLoanSimpleReceiver {
  function executeOperation(
    address asset,
    uint256 amount,
    uint256 premium,
    address initiator,
    bytes calldata params
  ) external returns (bool);
}

interface IMorpho {
  struct MarketParams {
    address loanToken;
    address collateralToken;
    address oracle;
    address irm;
    uint256 lltv;
  }

  function liquidate(
    MarketParams calldata marketParams,
    address borrower,
    uint256 seizedAssets,
    uint256 repaidShares,
    bytes calldata data
  ) external returns (uint256 seizedAssetsOut, uint256 repaidAssetsOut);
}

interface ISwapRouter02 {
  struct ExactInputParams {
    bytes path;
    address recipient;
    uint256 deadline;
    uint256 amountIn;
    uint256 amountOutMinimum;
  }

  function exactInput(ExactInputParams calldata params) external payable returns (uint256 amountOut);
}

///
/// LiquidationExecutor (Production-grade)
/// - Operators allowlist OR EIP712 signed orders (keeper mode)
/// - Pausable kill-switch
/// - Strict callback auth (Aave pool only)
/// - Profit guardrail + slippage guardrail + deadline + optional max gasPrice
/// - Observability via events
///
contract LiquidationExecutor is IFlashLoanSimpleReceiver, Ownable2Step, Pausable, ReentrancyGuard, EIP712 {
  using SafeERC20 for IERC20;

  // -----------------------------
  // Errors
  // -----------------------------
  error ZeroAddress();
  error NotOperator();
  error BadCaller();
  error BadInitiator();
  error AssetMismatch();
  error AmountMismatch();
  error DeadlineExpired();
  error GasPriceTooHigh();
  error ProfitTooLow();
  error NoCollateral();
  error InvalidLiquidationParams();
  error InvalidSignature();

  // -----------------------------
  // Events
  // -----------------------------
  event TreasuryUpdated(address indexed oldTreasury, address indexed newTreasury);
  event OperatorUpdated(address indexed operator, bool allowed);
  event OperatorModeUpdated(bool enabled);
  event SignerUpdated(address indexed oldSigner, address indexed newSigner);

  event Executed(
    address indexed executor,
    address indexed borrower,
    address indexed loanToken,
    address collateralToken,
    uint256 repayAmount,
    uint256 premium,
    uint256 collateralIn,
    uint256 loanOutFromSwap,
    uint256 profit
  );

  // -----------------------------
  // Immutable core deps
  // -----------------------------
  IPool public immutable aavePool;
  IMorpho public immutable morpho;
  ISwapRouter02 public immutable swapRouter;

  // -----------------------------
  // Config
  // -----------------------------
  address public treasury;

  // Operators allowlist
  bool public operatorModeEnabled = true;
  mapping(address => bool) public isOperator;

  // Optional: EIP-712 signer (keeper-mode). If signer == address(0), executeWithSig is disabled.
  address public signer;
  mapping(uint256 => bool) public usedNonces; // replay protection for signed orders

  // -----------------------------
  // Order types
  // -----------------------------
  struct Order {
    IMorpho.MarketParams market;
    address borrower;

    // Flashloan amount in loanToken
    uint256 repayAssets;

    // Morpho liquidation params:
    // Provide at least one of these non-zero:
    uint256 repaidShares;
    uint256 seizedAssets;

    // Uniswap V3 path collateral -> loanToken
    bytes uniPath;

    // Slippage guard: min output in loanToken
    uint256 amountOutMin;

    // Profit guardrail in loanToken (must be >= this after paying premium)
    uint256 minProfit;

    // Anti-stale
    uint256 deadline;

    // Optional: anti-bad conditions (0 disables)
    uint256 maxTxGasPrice;

    // Optional Aave referral code
    uint16 referralCode;

    // Replay protection for signed orders
    uint256 nonce;
  }

  struct CallbackData {
    Order order;
    address executor; // who initiated (operator / keeper)
  }

  // EIP-712: hash dynamic bytes via keccak256(path)
  bytes32 private constant ORDER_TYPEHASH =
    keccak256(
      "Order(address loanToken,address collateralToken,address oracle,address irm,uint256 lltv,address borrower,uint256 repayAssets,uint256 repaidShares,uint256 seizedAssets,bytes32 uniPathHash,uint256 amountOutMin,uint256 minProfit,uint256 deadline,uint256 maxTxGasPrice,uint16 referralCode,uint256 nonce)"
    );

  // -----------------------------
  // Constructor
  // -----------------------------
  constructor(
    address _aavePool,
    address _morpho,
    address _swapRouter,
    address _treasury
  ) Ownable(msg.sender) EIP712("LiquidationExecutor", "1") {
    if (_aavePool == address(0) || _morpho == address(0) || _swapRouter == address(0) || _treasury == address(0)) {
      revert ZeroAddress();
    }
    aavePool = IPool(_aavePool);
    morpho = IMorpho(_morpho);
    swapRouter = ISwapRouter02(_swapRouter);

    treasury = _treasury;

    // By default, owner is operator
    isOperator[msg.sender] = true;
    emit OperatorUpdated(msg.sender, true);
  }

  // -----------------------------
  // Admin
  // -----------------------------
  function setTreasury(address t) external onlyOwner {
    if (t == address(0)) revert ZeroAddress();
    emit TreasuryUpdated(treasury, t);
    treasury = t;
  }

  function setSigner(address s) external onlyOwner {
    emit SignerUpdated(signer, s);
    signer = s; // can be 0 to disable signed orders
  }

  function setOperator(address op, bool allowed) external onlyOwner {
    if (op == address(0)) revert ZeroAddress();
    isOperator[op] = allowed;
    emit OperatorUpdated(op, allowed);
  }

  function setOperatorModeEnabled(bool enabled) external onlyOwner {
    operatorModeEnabled = enabled;
    emit OperatorModeUpdated(enabled);
  }

  function pause() external onlyOwner {
    _pause(); // OZ already emits Paused(account)
  }

  function unpause() external onlyOwner {
    _unpause(); // OZ already emits Unpaused(account)
  }

  // -----------------------------
  // Execution (operator mode)
  // -----------------------------
  modifier onlyOperator() {
    if (operatorModeEnabled) {
      if (!isOperator[msg.sender]) revert NotOperator();
    } else {
      if (msg.sender != owner()) revert NotOperator();
    }
    _;
  }

  function execute(Order calldata order) external onlyOperator whenNotPaused {
    _precheck(order);
    aavePool.flashLoanSimple(
      address(this),
      order.market.loanToken,
      order.repayAssets,
      abi.encode(CallbackData({order: order, executor: msg.sender})),
      order.referralCode
    );
  }

  // -----------------------------
  // Execution (signed order, keeper mode)
  // Anyone can submit if they have a valid signature by `signer`.
  // -----------------------------
  function executeWithSig(Order calldata order, bytes calldata signature) external whenNotPaused {
    if (signer == address(0)) revert InvalidSignature();
    _precheck(order);

    if (usedNonces[order.nonce]) revert InvalidSignature();
    usedNonces[order.nonce] = true;

    bytes32 digest = _hashTypedDataV4(_hashOrder(order));
    address recovered = ECDSA.recover(digest, signature);
    if (recovered != signer) revert InvalidSignature();

    aavePool.flashLoanSimple(
      address(this),
      order.market.loanToken,
      order.repayAssets,
      abi.encode(CallbackData({order: order, executor: msg.sender})),
      order.referralCode
    );
  }

  // -----------------------------
  // Aave callback
  // -----------------------------
  function executeOperation(
    address asset,
    uint256 amount,
    uint256 premium,
    address initiator,
    bytes calldata params
  ) external override nonReentrant returns (bool) {
    if (msg.sender != address(aavePool)) revert BadCaller();
    if (initiator != address(this)) revert BadInitiator();

    CallbackData memory cb = abi.decode(params, (CallbackData));
    Order memory order = cb.order;

    if (asset != order.market.loanToken) revert AssetMismatch();
    if (amount != order.repayAssets) revert AmountMismatch();

    if (order.repaidShares == 0 && order.seizedAssets == 0) revert InvalidLiquidationParams();

    // 1) Liquidate on Morpho (Morpho pulls loanToken)
    IERC20(asset).forceApprove(address(morpho), amount);
    morpho.liquidate(order.market, order.borrower, order.seizedAssets, order.repaidShares, bytes(""));

    // 2) Swap collateral -> loanToken
    uint256 collBal = IERC20(order.market.collateralToken).balanceOf(address(this));
    if (collBal == 0) revert NoCollateral();

    IERC20(order.market.collateralToken).forceApprove(address(swapRouter), collBal);

    ISwapRouter02.ExactInputParams memory p = ISwapRouter02.ExactInputParams({
      path: order.uniPath,
      recipient: address(this),
      deadline: block.timestamp,
      amountIn: collBal,
      amountOutMinimum: order.amountOutMin
    });

    uint256 loanOut = swapRouter.exactInput(p);

    // 3) Repay Aave (Aave pulls loanToken)
    uint256 repayTotal = amount + premium;
    uint256 loanBal = IERC20(asset).balanceOf(address(this));
    if (loanBal < repayTotal + order.minProfit) revert ProfitTooLow();

    IERC20(asset).forceApprove(address(aavePool), repayTotal);

    // 4) Profit -> treasury
    uint256 profit = IERC20(asset).balanceOf(address(this)) - repayTotal;
    if (profit > 0) IERC20(asset).safeTransfer(treasury, profit);

    // Optional: sweep collateral dust to treasury
    uint256 collDust = IERC20(order.market.collateralToken).balanceOf(address(this));
    if (collDust > 0) IERC20(order.market.collateralToken).safeTransfer(treasury, collDust);

    emit Executed(cb.executor, order.borrower, asset, order.market.collateralToken, amount, premium, collBal, loanOut, profit);

    return true;
  }

  // -----------------------------
  // Rescue
  // -----------------------------
  function rescue(address token, uint256 amt, address to) external onlyOwner {
    if (to == address(0)) revert ZeroAddress();
    IERC20(token).safeTransfer(to, amt);
  }

  // -----------------------------
  // Internal helpers
  // -----------------------------
  function _precheck(Order calldata order) internal view {
    if (order.deadline < block.timestamp) revert DeadlineExpired();
    if (order.maxTxGasPrice != 0 && tx.gasprice > order.maxTxGasPrice) revert GasPriceTooHigh();
    if (order.market.loanToken == address(0) || order.market.collateralToken == address(0)) revert ZeroAddress();
    if (order.borrower == address(0)) revert ZeroAddress();
    if (treasury == address(0)) revert ZeroAddress();
    if (order.repayAssets == 0) revert AmountMismatch();
  }

  function _hashOrder(Order calldata o) internal pure returns (bytes32) {
    return keccak256(
      abi.encode(
        ORDER_TYPEHASH,
        o.market.loanToken,
        o.market.collateralToken,
        o.market.oracle,
        o.market.irm,
        o.market.lltv,
        o.borrower,
        o.repayAssets,
        o.repaidShares,
        o.seizedAssets,
        keccak256(o.uniPath),
        o.amountOutMin,
        o.minProfit,
        o.deadline,
        o.maxTxGasPrice,
        o.referralCode,
        o.nonce
      )
    );
  }
}
