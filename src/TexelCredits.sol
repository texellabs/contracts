// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @dev The two calls that the contract makes on a token.
interface ICreditsToken {
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
}

/// @title Texel credits: the deposits and the refunds of Texel credits in one contract
/// @notice A wallet buys Texel credits by sending USDG or $TEXEL to this contract in one plain
/// transfer. A wallet that pays with another token swaps it through Uniswap in the same
/// transaction, and the swap sends the USDG here. The gateway of Texel reads each payment and adds
/// the credits to the wallet that paid.
///
/// The USDG of unused credits stays here, so a refund always has the USDG to pay from. The
/// operator, the gas wallet of the gateway, sends the USDG of used credits on to the treasury, and
/// sends the $TEXEL of used credits to the burn address. A refund pays the unused credits of a
/// wallet back in the token they were bought with: USDG, or $TEXEL.
/// @dev The operator can do three things:
/// - pay a refund, each id once;
/// - send USDG to the treasury;
/// - send $TEXEL to the burn address.
/// A refund and a burn count against the daily cap of their token, the most of it that may leave
/// for anyone other than the treasury in one UTC day. A token with no cap cannot be refunded.
///
/// The treasury can take any token back to itself, set the daily cap of a token, and set the
/// operator, or set none to stop it. USDG, $TEXEL, and the treasury are fixed at the deploy. The
/// contract has no owner and cannot be upgraded, and ETH sent to it is refused.
contract TexelCredits {
    /// @notice The address that $TEXEL goes to when it is burned.
    address public constant BURN_ADDRESS = 0x000000000000000000000000000000000000dEaD;

    /// @notice USDG on Robinhood Chain: the token that every payment in another token becomes.
    address public immutable usdg;
    /// @notice $TEXEL, which buys credits as it is, without a swap.
    address public immutable texel;
    /// @notice The treasury of Texel, where the USDG of used credits goes.
    address public immutable treasury;

    /// @notice The gas wallet of the gateway of Texel, or none while the treasury stops it.
    address public operator;
    /// @notice For each token, the most of it that may leave in refunds and burns in one UTC day.
    mapping(address token => uint256) public dailyCap;
    /// @notice For each token and UTC day (the days since 1 Jan 1970), what left in refunds and burns.
    mapping(address token => mapping(uint256 day => uint256)) public sentOnDay;
    /// @notice The ids of the refunds paid, so that each pays once.
    mapping(bytes32 id => bool) public paid;

    /// @notice A refund went to a wallet.
    /// @param id The id of the refund, one for each refund that the gateway opens.
    /// @param token The token it paid: the token the credits were bought with.
    /// @param wallet The wallet whose unused credits it pays back.
    /// @param amount How much of the token it paid.
    event Refunded(bytes32 indexed id, address indexed token, address indexed wallet, uint256 amount);

    /// @notice The USDG of used credits went on to the treasury.
    /// @param amount The USDG that went, in the 6 decimals of USDG.
    event Forwarded(uint256 amount);

    /// @notice The $TEXEL of used credits went to the burn address.
    /// @param amount The $TEXEL that went, in the 18 decimals of $TEXEL.
    event Burned(uint256 amount);

    /// @notice The treasury took a token back to itself.
    /// @param token The token.
    /// @param amount How much of it went.
    event Released(address indexed token, uint256 amount);

    /// @notice The treasury set the operator.
    /// @param operator The new operator, or the zero address when there is none.
    event OperatorSet(address indexed operator);

    /// @notice The treasury set the daily cap of a token.
    /// @param token The token.
    /// @param cap The most of it that may leave in refunds and burns in one UTC day.
    event DailyCapSet(address indexed token, uint256 cap);

    /// @notice USDG, $TEXEL, the treasury, the first operator, and the wallet of a refund cannot be
    /// the zero address.
    error ZeroAddress();
    /// @notice USDG and $TEXEL are two different tokens.
    error SameToken();
    /// @notice Only the operator pays a refund, forwards, and burns.
    error NotOperator(address caller);
    /// @notice Only the treasury takes tokens back, sets a cap, and sets the operator.
    error NotTreasury(address caller);
    /// @notice A refund, a forward, a burn, and a release move more than nothing.
    error ZeroAmount();
    /// @notice A refund with this id was paid already.
    error AlreadyPaid(bytes32 id);
    /// @notice The refund or the burn would pass the daily cap of its token.
    /// @param token The token.
    /// @param left How much of it may still leave today.
    error OverDailyCap(address token, uint256 left);
    /// @notice The token refused to send the amount.
    error TransferFailed(address token, uint256 amount);

    /// @dev With no operator set, no caller passes, the zero address included.
    modifier onlyOperator() {
        if (msg.sender != operator || operator == address(0)) revert NotOperator(msg.sender);
        _;
    }

    modifier onlyTreasury() {
        if (msg.sender != treasury) revert NotTreasury(msg.sender);
        _;
    }

    /// @param usdg_ USDG on Robinhood Chain.
    /// @param texel_ $TEXEL on Robinhood Chain.
    /// @param treasury_ The treasury of Texel.
    /// @param operator_ The gas wallet of the gateway of Texel.
    /// @param usdgDailyCap_ The daily cap of USDG, in the 6 decimals of USDG.
    /// @param texelDailyCap_ The daily cap of $TEXEL, in the 18 decimals of $TEXEL.
    constructor(
        address usdg_,
        address texel_,
        address treasury_,
        address operator_,
        uint256 usdgDailyCap_,
        uint256 texelDailyCap_
    ) {
        if (usdg_ == address(0) || texel_ == address(0) || treasury_ == address(0) || operator_ == address(0)) {
            revert ZeroAddress();
        }
        if (usdg_ == texel_) revert SameToken();
        usdg = usdg_;
        texel = texel_;
        treasury = treasury_;
        operator = operator_;
        emit OperatorSet(operator_);
        _setDailyCap(usdg_, usdgDailyCap_);
        _setDailyCap(texel_, texelDailyCap_);
    }

    /// @notice Pays a refund of unused credits to a wallet, in the token they were bought with.
    /// A refund above what the contract holds, or above what its token may still send today,
    /// fails and pays nothing.
    /// @param id The id of the refund: a second refund with it fails.
    /// @param token The token to pay: USDG, $TEXEL, or another token that the treasury gave a cap.
    /// @param wallet The wallet that gets the token.
    /// @param amount How much of the token to pay.
    function refund(bytes32 id, address token, address wallet, uint256 amount) external onlyOperator {
        if (wallet == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        if (paid[id]) revert AlreadyPaid(id);
        paid[id] = true;
        _countToday(token, amount);
        _send(token, wallet, amount);
        emit Refunded(id, token, wallet, amount);
    }

    /// @notice Sends the USDG of used credits on to the treasury. It does not count against the
    /// daily cap, since the USDG goes nowhere but the treasury.
    /// @param amount The USDG to send, in the 6 decimals of USDG.
    function forward(uint256 amount) external onlyOperator {
        if (amount == 0) revert ZeroAmount();
        _send(usdg, treasury, amount);
        emit Forwarded(amount);
    }

    /// @notice Sends the $TEXEL of used credits to the burn address. It counts against the daily
    /// cap of $TEXEL.
    /// @param amount The $TEXEL to burn, in the 18 decimals of $TEXEL.
    function burn(uint256 amount) external onlyOperator {
        if (amount == 0) revert ZeroAmount();
        _countToday(texel, amount);
        _send(texel, BURN_ADDRESS, amount);
        emit Burned(amount);
    }

    /// @notice Sends a token that the contract holds back to the treasury: USDG, $TEXEL, or any
    /// other token that a wallet sent here by mistake.
    /// @param token The token to send back.
    /// @param amount How much of it to send.
    function release(address token, uint256 amount) external onlyTreasury {
        if (amount == 0) revert ZeroAmount();
        _send(token, treasury, amount);
        emit Released(token, amount);
    }

    /// @notice Sets the operator, such as a new gas wallet, or the zero address to stop every call
    /// of the operator until the treasury sets one again.
    /// @param newOperator The new operator.
    function setOperator(address newOperator) external onlyTreasury {
        operator = newOperator;
        emit OperatorSet(newOperator);
    }

    /// @notice Sets the most of a token that may leave in refunds and burns in one UTC day. Zero
    /// stops its refunds and burns.
    /// @param token The token.
    /// @param cap The new daily cap.
    function setDailyCap(address token, uint256 cap) external onlyTreasury {
        _setDailyCap(token, cap);
    }

    /// @notice How much of a token may still leave in refunds and burns today.
    /// @param token The token.
    /// @return left The daily cap of the token less what left today, or zero once it is passed.
    function leftToday(address token) public view returns (uint256 left) {
        uint256 cap = dailyCap[token];
        uint256 sent = sentOnDay[token][today()];
        return sent >= cap ? 0 : cap - sent;
    }

    /// @notice The UTC day of the current block: the days since 1 Jan 1970.
    function today() public view returns (uint256) {
        return block.timestamp / 1 days;
    }

    /// @dev Counts an amount that leaves today against the daily cap of its token, or fails.
    function _countToday(address token, uint256 amount) private {
        uint256 left = leftToday(token);
        if (amount > left) revert OverDailyCap(token, left);
        sentOnDay[token][today()] += amount;
    }

    function _setDailyCap(address token, uint256 cap) private {
        if (token == address(0)) revert ZeroAddress();
        dailyCap[token] = cap;
        emit DailyCapSet(token, cap);
    }

    /// @dev Sends a token and fails when the token refuses. The reason of a token that reverts,
    /// such as a wallet it blocks, comes through as it is. A token that returns nothing counts
    /// as a success, as SafeERC20 of OpenZeppelin counts it.
    function _send(address token, address to, uint256 amount) private {
        (bool ok, bytes memory data) = token.call(abi.encodeCall(ICreditsToken.transfer, (to, amount)));
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
