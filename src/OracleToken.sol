// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "./interfaces/IERC20.sol";

/// @title OracleToken — "AutonomoUs oracle" (ORACLE)
/// @notice A fixed-supply ERC-20. The whole supply, 1,000,000,000 ORACLE with 18 decimals, is minted
///         once to the deployer in the constructor. There is no owner, no minter, no pause, no
///         blocklist, no fee and no hook: after deployment nobody holds any power over the token that
///         an ordinary holder does not have over their own balance.
/// @dev Self-contained on purpose: no library, no delegatecall, no upgradeability. The Solidity
///      identifier `OracleToken` is what a launch manifest records; `name()` returns the token's
///      display name. The supply is a compile-time constant because nothing can ever mint or burn.
contract OracleToken is IERC20 {
    // ---------------------------------------------------------------------
    // Errors (same names and arguments as the ERC-6093 standard errors)
    // ---------------------------------------------------------------------

    /// @notice `sender` tried to move `needed` but holds only `balance`.
    error ERC20InsufficientBalance(address sender, uint256 balance, uint256 needed);
    /// @notice A transfer named the zero address as recipient.
    error ERC20InvalidReceiver(address receiver);
    /// @notice An approval named the zero address as spender.
    error ERC20InvalidSpender(address spender);
    /// @notice `spender` tried to move `needed` from an owner that allowed only `allowance`.
    error ERC20InsufficientAllowance(address spender, uint256 allowance, uint256 needed);

    // ---------------------------------------------------------------------
    // Constants
    // ---------------------------------------------------------------------

    string private constant NAME = "AutonomoUs oracle";
    string private constant SYMBOL = "ORACLE";
    uint8 private constant DECIMALS = 18;

    /// @notice The entire supply, in minor units: 1,000,000,000 * 10^18.
    uint256 public constant TOTAL_SUPPLY = 1_000_000_000 * 10 ** uint256(DECIMALS);

    // ---------------------------------------------------------------------
    // Storage
    // ---------------------------------------------------------------------

    mapping(address account => uint256) private _balances;
    mapping(address owner => mapping(address spender => uint256)) private _allowances;

    // ---------------------------------------------------------------------
    // Construction
    // ---------------------------------------------------------------------

    /// @notice Mints the whole supply to the deployer (`msg.sender`). Takes no arguments.
    constructor() {
        _balances[msg.sender] = TOTAL_SUPPLY;
        emit Transfer(address(0), msg.sender, TOTAL_SUPPLY);
    }

    // ---------------------------------------------------------------------
    // Metadata
    // ---------------------------------------------------------------------

    /// @inheritdoc IERC20
    function name() external pure returns (string memory) {
        return NAME;
    }

    /// @inheritdoc IERC20
    function symbol() external pure returns (string memory) {
        return SYMBOL;
    }

    /// @inheritdoc IERC20
    function decimals() external pure returns (uint8) {
        return DECIMALS;
    }

    // ---------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------

    /// @inheritdoc IERC20
    /// @dev Constant: nothing can mint or burn after construction.
    function totalSupply() external pure returns (uint256) {
        return TOTAL_SUPPLY;
    }

    /// @inheritdoc IERC20
    function balanceOf(address account) external view returns (uint256) {
        return _balances[account];
    }

    /// @inheritdoc IERC20
    function allowance(address owner, address spender) external view returns (uint256) {
        return _allowances[owner][spender];
    }

    // ---------------------------------------------------------------------
    // Mutations
    // ---------------------------------------------------------------------

    /// @inheritdoc IERC20
    /// @dev Reverts with `ERC20InvalidReceiver` for the zero address and `ERC20InsufficientBalance`
    ///      when the caller holds less than `value`. A zero-value transfer succeeds and emits.
    function transfer(address to, uint256 value) external returns (bool) {
        _transfer(msg.sender, to, value);
        return true;
    }

    /// @inheritdoc IERC20
    /// @dev Sets the allowance outright (no increase/decrease semantics). Reverts with
    ///      `ERC20InvalidSpender` for the zero address.
    function approve(address spender, uint256 value) external returns (bool) {
        if (spender == address(0)) revert ERC20InvalidSpender(address(0));
        _allowances[msg.sender][spender] = value;
        emit Approval(msg.sender, spender, value);
        return true;
    }

    /// @inheritdoc IERC20
    /// @dev An allowance of `type(uint256).max` is treated as unlimited and is not decreased.
    ///      Otherwise the allowance is reduced by `value` and reverts with
    ///      `ERC20InsufficientAllowance` when it is too small. No `Approval` event is emitted on
    ///      the decrease, matching the common ERC-20 convention.
    function transferFrom(address from, address to, uint256 value) external returns (bool) {
        uint256 current = _allowances[from][msg.sender];
        if (current != type(uint256).max) {
            if (current < value) revert ERC20InsufficientAllowance(msg.sender, current, value);
            unchecked {
                _allowances[from][msg.sender] = current - value;
            }
        }
        _transfer(from, to, value);
        return true;
    }

    // ---------------------------------------------------------------------
    // Internals
    // ---------------------------------------------------------------------

    function _transfer(address from, address to, uint256 value) private {
        if (to == address(0)) revert ERC20InvalidReceiver(address(0));
        uint256 fromBalance = _balances[from];
        if (fromBalance < value) revert ERC20InsufficientBalance(from, fromBalance, value);
        unchecked {
            // `fromBalance >= value` was just checked, and the sum of all balances is the constant
            // TOTAL_SUPPLY, so the recipient's balance cannot overflow.
            _balances[from] = fromBalance - value;
            _balances[to] += value;
        }
        emit Transfer(from, to, value);
    }
}
