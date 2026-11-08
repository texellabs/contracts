// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @dev The calls that Earn makes to a token.
interface IEarnToken {
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
}

/// @title Earn: tokenized NVDA for every wallet with $TEXEL
/// @notice Texel sends tokenized NVDA on Robinhood Chain to this contract. Each round, the
/// publisher of Texel writes one Merkle root: for every wallet with $TEXEL, the NVDA it has
/// earned since the first round, split by how much $TEXEL it had over the time of each round. A
/// claim pays a wallet what its amount holds beyond what the wallet got before. Anyone may send a
/// claim, and the NVDA always goes to the wallet of the leaf, so Texel can pay every wallet with
/// no step of the wallet. A leaf is `(address account, uint256 cumulative)`, and the tree is the
/// StandardMerkleTree of OpenZeppelin.
/// @dev Three rules keep the NVDA of the wallets safe:
/// - `allocated`, the NVDA that the root holds over every round, never goes down;
/// - a root is published only while the contract holds all of its NVDA that is not claimed yet;
/// - claims never pay more in total than `allocated`.
/// So NVDA that a root holds leaves only to its wallets, and the owner can take back only
/// `surplus()`, the NVDA that no root holds yet. The contract cannot be upgraded.
contract TexelEarn {
    /// @notice One claim of `claimMany`.
    /// @param account The wallet that gets the NVDA.
    /// @param cumulative The NVDA that the wallet has earned over every round, as the root holds it.
    /// @param proof The nodes from the leaf to the root.
    struct Claim {
        address account;
        uint256 cumulative;
        bytes32[] proof;
    }

    /// @notice The token that Earn pays: tokenized NVDA on Robinhood Chain.
    address public immutable reward;

    /// @notice The owner names the publisher and takes back the surplus: the treasury of Texel.
    address public owner;
    /// @notice The address that becomes the owner once it accepts.
    address public pendingOwner;
    /// @notice The only address that publishes a root: the gas wallet of Texel. The zero address
    /// stops the rounds.
    address public publisher;

    /// @notice The number of the latest round, or zero before the first one.
    uint64 public round;
    /// @notice The last block of Robinhood Chain that the latest round counts, as the RPC numbers
    /// the blocks. The EVM of an Arbitrum chain gives another number to `block.number`.
    uint64 public endBlock;
    /// @notice The root of the latest round, or zero before the first one.
    bytes32 public root;
    /// @notice The NVDA of every wallet over every round, as the latest root holds it.
    uint256 public allocated;
    /// @notice The NVDA that all claims together have paid.
    uint256 public claimedTotal;
    /// @notice The NVDA that each wallet has got over every round.
    mapping(address account => uint256 amount) public claimed;

    /// @notice A round got its root.
    /// @param round The number of the round, from 1.
    /// @param root The Merkle root of every wallet and its NVDA over every round.
    /// @param allocated The NVDA of every wallet over every round.
    /// @param added The NVDA that this round adds.
    /// @param endBlock The last block of Robinhood Chain that the round counts.
    event Published(uint64 indexed round, bytes32 root, uint256 allocated, uint256 added, uint64 endBlock);
    /// @notice A wallet got NVDA.
    /// @param account The wallet.
    /// @param amount The NVDA it got now.
    /// @param cumulative The NVDA it has got over every round.
    event Claimed(address indexed account, uint256 amount, uint256 cumulative);
    /// @notice The owner named a publisher, or the zero address to stop the rounds.
    event PublisherSet(address indexed publisher);
    /// @notice The owner offered the contract to a new owner, or the zero address to cancel.
    event OwnershipTransferStarted(address indexed owner, address indexed pendingOwner);
    /// @notice The contract has a new owner.
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    /// @notice The owner took back a token: NVDA that no root holds, or a token sent here by mistake.
    event Recovered(address indexed token, address indexed to, uint256 amount);

    /// @notice An address that must be set is the zero address.
    error ZeroAddress();
    /// @notice The reward token has no code.
    error NotAContract(address token);
    /// @notice Only the owner may do this.
    error NotOwner();
    /// @notice Only the pending owner accepts the contract.
    error NotPendingOwner();
    /// @notice Only the publisher publishes a root.
    error NotPublisher();
    /// @notice A round has the number after the latest one, so a round is published once.
    error WrongRound(uint64 expected, uint64 given);
    /// @notice A round needs a root.
    error ZeroRoot();
    /// @notice A round counts blocks after those of the round before it.
    error EndBlockNotAfter(uint64 last, uint64 given);
    /// @notice The NVDA of every round together never goes down.
    error AllocationDecreased(uint256 allocated, uint256 given);
    /// @notice The contract does not hold the NVDA that the root holds and nobody has claimed yet.
    error Unfunded(uint256 needed, uint256 held);
    /// @notice The leaf of the wallet and its amount is not in the root of the latest round.
    error InvalidProof(address account);
    /// @notice The wallet has got all of its amount already.
    error NothingToClaim(address account);
    /// @notice The claims would pay more than the NVDA of every round together.
    error OverAllocated(uint256 paid, uint256 allocated);
    /// @notice The owner takes back only NVDA that no root holds.
    error OverSurplus(uint256 amount, uint256 surplus);
    /// @notice The token refused a transfer.
    error TransferFailed(address token, address to, uint256 amount);

    /// @param reward_ Tokenized NVDA on Robinhood Chain.
    /// @param owner_ The treasury of Texel.
    /// @param publisher_ The gas wallet of Texel.
    constructor(address reward_, address owner_, address publisher_) {
        if (owner_ == address(0) || publisher_ == address(0)) revert ZeroAddress();
        if (reward_.code.length == 0) revert NotAContract(reward_);
        reward = reward_;
        owner = owner_;
        publisher = publisher_;
        emit OwnershipTransferred(address(0), owner_);
        emit PublisherSet(publisher_);
    }

    /// @notice Publishes the root of the next round. The root holds every wallet that has earned
    /// NVDA in any round, with what it has earned over every round, so it replaces the root before.
    /// @param number The number of the round: the one after the latest.
    /// @param newRoot The Merkle root of every wallet and its NVDA over every round.
    /// @param newAllocated The NVDA of every wallet over every round: the sum of the root.
    /// @param newEndBlock The last block of Robinhood Chain that the round counts.
    function publish(uint64 number, bytes32 newRoot, uint256 newAllocated, uint64 newEndBlock) external {
        if (msg.sender != publisher) revert NotPublisher();
        if (number != round + 1) revert WrongRound(round + 1, number);
        if (newRoot == bytes32(0)) revert ZeroRoot();
        if (newEndBlock <= endBlock) revert EndBlockNotAfter(endBlock, newEndBlock);
        uint256 before = allocated;
        if (newAllocated < before) revert AllocationDecreased(before, newAllocated);
        uint256 unclaimed = newAllocated - claimedTotal;
        uint256 held = _held();
        if (unclaimed > held) revert Unfunded(unclaimed, held);
        round = number;
        endBlock = newEndBlock;
        root = newRoot;
        allocated = newAllocated;
        emit Published(number, newRoot, newAllocated, newAllocated - before, newEndBlock);
    }

    /// @notice Pays a wallet the part of its amount that it has not got yet. Anyone may call it,
    /// and the NVDA goes to the wallet.
    /// @param account The wallet of the leaf.
    /// @param cumulative The NVDA that the wallet has earned over every round, as the root holds it.
    /// @param proof The nodes from the leaf to the root.
    /// @return amount The NVDA paid now.
    function claim(address account, uint256 cumulative, bytes32[] calldata proof) external returns (uint256 amount) {
        amount = _claim(account, cumulative, proof);
        if (amount == 0) revert NothingToClaim(account);
    }

    /// @notice Pays many wallets at once, as `claim` does. A wallet that has got all of its
    /// amount is skipped; a proof that does not fit fails the whole call.
    /// @param claims The wallets, their amounts, and their proofs.
    /// @return total The NVDA paid now to all of them.
    function claimMany(Claim[] calldata claims) external returns (uint256 total) {
        for (uint256 i = 0; i < claims.length; ++i) {
            total += _claim(claims[i].account, claims[i].cumulative, claims[i].proof);
        }
    }

    /// @notice The NVDA that the contract holds beyond what the root holds for the wallets: the
    /// NVDA of the next round.
    function surplus() public view returns (uint256) {
        uint256 held = _held();
        uint256 unclaimed = allocated - claimedTotal;
        return held > unclaimed ? held - unclaimed : 0;
    }

    /// @notice Sends a token back from the contract: NVDA only up to `surplus()`, any other token
    /// in full.
    /// @param token The token.
    /// @param to The address that gets it.
    /// @param amount How much.
    function recover(address token, address to, uint256 amount) external {
        if (msg.sender != owner) revert NotOwner();
        if (to == address(0)) revert ZeroAddress();
        if (token == reward) {
            uint256 free = surplus();
            if (amount > free) revert OverSurplus(amount, free);
        }
        emit Recovered(token, to, amount);
        _send(token, to, amount);
    }

    /// @notice Names the publisher, or the zero address to stop the rounds. Claims of the latest
    /// root go on either way.
    function setPublisher(address newPublisher) external {
        if (msg.sender != owner) revert NotOwner();
        publisher = newPublisher;
        emit PublisherSet(newPublisher);
    }

    /// @notice Offers the contract to a new owner, who must accept it. The zero address cancels.
    function transferOwnership(address newOwner) external {
        if (msg.sender != owner) revert NotOwner();
        pendingOwner = newOwner;
        emit OwnershipTransferStarted(owner, newOwner);
    }

    /// @notice The pending owner takes the contract.
    function acceptOwnership() external {
        if (msg.sender != pendingOwner) revert NotPendingOwner();
        emit OwnershipTransferred(owner, msg.sender);
        owner = msg.sender;
        pendingOwner = address(0);
    }

    /// @dev Checks a leaf and pays what it holds beyond the claims before it: the state first,
    /// then the transfer.
    function _claim(address account, uint256 cumulative, bytes32[] calldata proof) private returns (uint256 amount) {
        if (!_inRoot(_leaf(account, cumulative), proof)) revert InvalidProof(account);
        uint256 before = claimed[account];
        if (cumulative <= before) return 0;
        amount = cumulative - before;
        uint256 paid = claimedTotal + amount;
        if (paid > allocated) revert OverAllocated(paid, allocated);
        claimed[account] = cumulative;
        claimedTotal = paid;
        emit Claimed(account, amount, cumulative);
        _send(reward, account, amount);
    }

    /// @dev The leaf of the StandardMerkleTree of OpenZeppelin for the types (address, uint256). The
    /// double hash keeps a node inside the tree from passing as a leaf.
    function _leaf(address account, uint256 cumulative) private pure returns (bytes32) {
        return keccak256(bytes.concat(keccak256(abi.encode(account, cumulative))));
    }

    /// @dev Whether a leaf and its proof lead to the root of the latest round. Before the first
    /// round the root is zero, and no hash is zero.
    function _inRoot(bytes32 leaf, bytes32[] calldata proof) private view returns (bool) {
        bytes32 node = leaf;
        for (uint256 i = 0; i < proof.length; ++i) {
            node = _hashPair(node, proof[i]);
        }
        return node == root;
    }

    /// @dev keccak-256 of the two nodes, the lower one first, as MerkleProof of OpenZeppelin.
    function _hashPair(bytes32 a, bytes32 b) private pure returns (bytes32 value) {
        (bytes32 low, bytes32 high) = a < b ? (a, b) : (b, a);
        assembly ("memory-safe") {
            mstore(0x00, low)
            mstore(0x20, high)
            value := keccak256(0x00, 0x40)
        }
    }

    /// @dev The NVDA that the contract holds.
    function _held() private view returns (uint256) {
        return IEarnToken(reward).balanceOf(address(this));
    }

    /// @dev Sends a token and fails when the token refuses. The reason of a token that reverts,
    /// such as a wallet it blocks, comes through as it is. A token that returns nothing counts as
    /// a success, as SafeERC20 of OpenZeppelin counts it.
    function _send(address token, address to, uint256 amount) private {
        (bool ok, bytes memory data) = token.call(abi.encodeCall(IEarnToken.transfer, (to, amount)));
        if (!ok) {
            if (data.length == 0) revert TransferFailed(token, to, amount);
            assembly ("memory-safe") {
                revert(add(data, 0x20), mload(data))
            }
        }
        if (data.length == 0 ? token.code.length == 0 : !abi.decode(data, (bool))) {
            revert TransferFailed(token, to, amount);
        }
    }
}
