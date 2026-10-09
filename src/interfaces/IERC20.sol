// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title IERC20
/// @notice The ERC-20 interface (EIP-20) with the optional metadata extension, as the token implements it.
interface IERC20 {
    /// @notice Emitted when `value` tokens move from `from` to `to`. Minting emits it with `from` as the zero address.
    event Transfer(address indexed from, address indexed to, uint256 value);

    /// @notice Emitted when `owner` sets the allowance of `spender` to `value`.
    event Approval(address indexed owner, address indexed spender, uint256 value);

    function name() external view returns (string memory);
    function symbol() external view returns (string memory);
    function decimals() external view returns (uint8);
    function totalSupply() external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function allowance(address owner, address spender) external view returns (uint256);
    function transfer(address to, uint256 value) external returns (bool);
    function approve(address spender, uint256 value) external returns (bool);
    function transferFrom(address from, address to, uint256 value) external returns (bool);
}
