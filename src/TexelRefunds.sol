// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @dev The two calls that the contract makes on a token.
interface IRefundToken {
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
}

/// @title The refunds of unused Texel credits
/// @notice A wallet that does not use its Texel credits gets back the USDG they cost from this
/// contract. The treasury of Texel keeps USDG here for refunds. When a wallet asks for a refund,
/// the gateway of Texel takes its unused credits from its balance, and the operator, the gas
/// wallet of the gateway, sends the USDG from here to that wallet, with one id for each refund.
/// @dev The operator can only pay refunds: each id pays once, only from the USDG that the
/// contract holds. The treasury can only take tokens back to itself. Both are fixed at the
/// deploy. The contract has no owner and cannot be upgraded, and ETH sent to it is refused.
contract TexelRefunds {
    /// @notice USDG on Robinhood Chain: the token of every refund.
    address public immutable usdg;
    /// @notice The treasury of Texel, which keeps USDG here and is the one place it goes back to.
    address public immutable treasury;
    /// @notice The only address that pays a refund: the gas wallet of the gateway of Texel.
    address public immutable operator;

    /// @notice The ids of the refunds paid, so that each pays once.
    mapping(bytes32 id => bool) public paid;

    /// @notice A refund went to a wallet.
    /// @param id The id of the refund, one for each refund that the gateway opens.
    /// @param wallet The wallet whose unused credits it pays back.
    /// @param amount The USDG it paid, in the 6 decimals of USDG.
    event Refunded(bytes32 indexed id, address indexed wallet, uint256 amount);

    /// @notice A token that the contract held went back to the treasury.
    /// @param token The token.
    /// @param amount How much of it went.
    event Released(address indexed token, uint256 amount);

    /// @notice USDG, the treasury, the operator, and the wallet of a refund cannot be the zero address.
    error ZeroAddress();
    /// @notice Only the operator pays a refund.
    error NotOperator(address caller);
    /// @notice Only the treasury takes tokens back.
    error NotTreasury(address caller);
    /// @notice A refund pays more than nothing.
    error ZeroAmount();
    /// @notice A refund with this id was paid already.
    error AlreadyPaid(bytes32 id);
    /// @notice The token refused to send the amount.
    error TransferFailed(address token, uint256 amount);

    /// @param usdg_ USDG on Robinhood Chain.
    /// @param treasury_ The treasury of Texel.
    /// @param operator_ The gas wallet of the gateway of Texel.
    constructor(address usdg_, address treasury_, address operator_) {
        if (usdg_ == address(0) || treasury_ == address(0) || operator_ == address(0)) {
            revert ZeroAddress();
        }
        usdg = usdg_;
        treasury = treasury_;
        operator = operator_;
    }

    /// @notice Pays a refund of unused credits to a wallet, in USDG that the contract holds.
    /// A refund above what the contract holds fails and pays nothing.
    /// @param id The id of the refund: a second refund with it fails.
    /// @param wallet The wallet that gets the USDG.
    /// @param amount The USDG to pay, in the 6 decimals of USDG.
    function refund(bytes32 id, address wallet, uint256 amount) external {
        if (msg.sender != operator) revert NotOperator(msg.sender);
        if (wallet == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        if (paid[id]) revert AlreadyPaid(id);
        paid[id] = true;
        _send(usdg, wallet, amount);
        emit Refunded(id, wallet, amount);
    }

    /// @notice Sends all of a token that the contract holds back to the treasury: the USDG kept
    /// for refunds, or any other token that a wallet sent here by mistake.
    /// @param token The token to send back.
    /// @return amount How much went to the treasury: zero when the contract held none.
    function release(address token) external returns (uint256 amount) {
        if (msg.sender != treasury) revert NotTreasury(msg.sender);
        amount = IRefundToken(token).balanceOf(address(this));
        if (amount == 0) return 0;
        _send(token, treasury, amount);
        emit Released(token, amount);
    }

    /// @dev Sends a token and fails when the token refuses. The reason of a token that reverts,
    /// such as a wallet it blocks, comes through as it is. A token that returns nothing counts
    /// as a success, as SafeERC20 of OpenZeppelin counts it.
    function _send(address token, address to, uint256 amount) private {
        (bool ok, bytes memory data) = token.call(abi.encodeCall(IRefundToken.transfer, (to, amount)));
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
