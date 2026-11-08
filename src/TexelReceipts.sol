// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @title The hourly seals of the receipts of Texel
/// @notice Each rental of a GPU and each output of a model on Texel gets one receipt. After
/// each UTC hour, the gateway of Texel writes one Merkle root of the receipts of that hour
/// here. The format of a receipt is version 1, whose fields `ReceiptFields` in
/// test/TexelReceipts.t.sol lists in the order of its leaf, and the tree is the
/// StandardMerkleTree of OpenZeppelin.
/// @dev An hour is sealed once and never changes. The contract holds no money, has no owner,
/// and cannot be upgraded.
contract TexelReceipts {
    /// @notice The seal of one hour.
    /// @param root The Merkle root of the receipts of the hour, or zero for an hour with none.
    /// @param count How many receipts the root holds.
    /// @param sealedAt The block time of the seal, or zero while the hour is not sealed.
    struct Seal {
        bytes32 root;
        uint32 count;
        uint64 sealedAt;
    }

    /// @dev The length of an hour, in seconds.
    uint64 private constant HOUR = 3600;

    /// @notice The only address that seals an hour: the gas wallet of the gateway of Texel.
    address public immutable sealer;

    /// @dev The seal of each hour, by the start of the hour in seconds since 1970.
    mapping(uint64 hour => Seal) private _seals;

    /// @notice An hour got its root.
    /// @param hour The start of the hour, in seconds since 1970.
    /// @param root The Merkle root of its receipts, or zero for an hour with none.
    /// @param count How many receipts the root holds.
    event Sealed(uint64 indexed hour, bytes32 root, uint32 count);

    /// @notice The sealer cannot be the zero address.
    error ZeroSealer();
    /// @notice Only the sealer seals an hour.
    error NotSealer();
    /// @notice The hour is not the start of a UTC hour.
    error NotAnHour(uint64 hour);
    /// @notice The hour has not ended yet.
    error HourNotOver(uint64 hour);
    /// @notice The hour has its seal already, and a seal never changes.
    error AlreadySealed(uint64 hour);
    /// @notice An hour with no receipt has a zero root, and an hour with receipts has a root.
    error RootDoesNotFitCount();

    /// @param sealer_ The gas wallet of the gateway of Texel.
    constructor(address sealer_) {
        if (sealer_ == address(0)) revert ZeroSealer();
        sealer = sealer_;
    }

    /// @notice Writes the root of the receipts of an hour that has ended. Each hour takes one
    /// seal, an hour with no receipt too, so nothing is added to an hour later.
    /// @param hour The start of the hour, in seconds since 1970.
    /// @param root The Merkle root of the receipts of the hour, or zero for an hour with none.
    /// @param count How many receipts the root holds.
    function seal(uint64 hour, bytes32 root, uint32 count) external {
        if (msg.sender != sealer) revert NotSealer();
        if (hour % HOUR != 0) revert NotAnHour(hour);
        // The time of a block may be off by seconds, and the sealer waits minutes past the hour.
        // forge-lint: disable-next-line(block-timestamp)
        if (uint256(hour) + HOUR > block.timestamp) revert HourNotOver(hour);
        if (_seals[hour].sealedAt != 0) revert AlreadySealed(hour);
        if ((count == 0) != (root == bytes32(0))) revert RootDoesNotFitCount();
        _seals[hour] = Seal({root: root, count: count, sealedAt: uint64(block.timestamp)});
        emit Sealed(hour, root, count);
    }

    /// @notice The seal of an hour. A `sealedAt` of zero means the hour is not sealed.
    /// @param hour The start of the hour, in seconds since 1970.
    function seals(uint64 hour) external view returns (bytes32 root, uint32 count, uint64 sealedAt) {
        Seal storage kept = _seals[hour];
        return (kept.root, kept.count, kept.sealedAt);
    }

    /// @notice Whether a receipt is in the root of its hour. False for an hour with no seal and
    /// for an hour with no receipt.
    /// @dev Compute the leaf from the fields of the receipt. The contract sees hashes only, so a
    /// node inside the tree passes as well; the double hash of a leaf keeps such a node from
    /// standing for a receipt.
    /// @param hour The start of the hour of the receipt, in seconds since 1970.
    /// @param leaf The leaf of the receipt: keccak-256 of keccak-256 of its ABI encoding.
    /// @param proof The nodes from the leaf to the root.
    function verify(uint64 hour, bytes32 leaf, bytes32[] calldata proof) external view returns (bool) {
        bytes32 root = _seals[hour].root;
        if (root == bytes32(0)) return false;
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
}
