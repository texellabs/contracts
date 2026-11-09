// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @dev The two calls that the contract makes on a token.
interface IDepositToken {
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
}

/// @title The deposit address of Texel credits
/// @notice A wallet buys Texel credits by sending USDG to this contract in one plain transfer.
/// The gateway of Texel reads each Transfer of USDG to this address and adds the credits to the
/// wallet that sent it. `forward` sends what the contract holds on to the treasury of Texel.
/// @dev A deposit takes no approval and no signature, only the transfer itself. The contract has
/// no owner and cannot be upgraded. A token leaves it only for the treasury, which is fixed at
/// the deploy, so anyone may call `forward`. ETH sent to it is refused.
contract TexelDeposits {
    /// @notice USDG on Robinhood Chain: the token that buys Texel credits.
    address public immutable usdg;
    /// @notice The treasury of Texel, where every token sent here ends.
    address public immutable treasury;

    /// @notice A token that the contract held went on to the treasury.
    /// @param token The token.
    /// @param amount How much of it went.
    event Forwarded(address indexed token, uint256 amount);

    /// @notice USDG and the treasury cannot be the zero address.
    error ZeroAddress();
    /// @notice The token refused to send the amount to the treasury.
    error TransferFailed(address token, uint256 amount);

    /// @param usdg_ USDG on Robinhood Chain.
    /// @param treasury_ The treasury of Texel.
    constructor(address usdg_, address treasury_) {
        if (usdg_ == address(0) || treasury_ == address(0)) revert ZeroAddress();
        usdg = usdg_;
        treasury = treasury_;
    }

    /// @notice Sends all of a token that the contract holds to the treasury: USDG after deposits,
    /// or any other token that a wallet sent here by mistake.
    /// @param token The token to send on.
    /// @return amount How much went to the treasury: zero when the contract held none.
    function forward(address token) external returns (uint256 amount) {
        amount = IDepositToken(token).balanceOf(address(this));
        if (amount == 0) return 0;
        _send(token, amount);
        emit Forwarded(token, amount);
    }

    /// @dev Sends a token to the treasury and fails when the token refuses. The reason of a token
    /// that reverts, such as a wallet it blocks, comes through as it is. A token that returns
    /// nothing counts as a success, as SafeERC20 of OpenZeppelin counts it.
    function _send(address token, uint256 amount) private {
        (bool ok, bytes memory data) = token.call(abi.encodeCall(IDepositToken.transfer, (treasury, amount)));
        if (!ok) {
            if (data.length == 0) revert TransferFailed(token, amount);
            assembly ("memory-safe") {
                revert(add(data, 0x20), mload(data))
            }
        }
        if (data.length == 0 ? token.code.length == 0 : !abi.decode(data, (bool))) {
            revert TransferFailed(token, amount);
        }
    }
}
