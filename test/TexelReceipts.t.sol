// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {TexelReceipts} from "../src/TexelReceipts.sol";

contract TexelReceiptsTest is Test {
    event Sealed(uint64 indexed hour, bytes32 root, uint32 count);

    /// The fields of a receipt of version 1, in the order of its leaf.
    struct ReceiptFields {
        uint64 hour;
        string kind;
        string item;
        uint32 width;
        uint32 height;
        uint32 duration;
        uint32 characters;
        uint64 credits;
        bool free;
        bytes32 code;
    }

    uint64 internal constant HOUR = 3600;
    /// 2026-11-07T10:00:00Z, the hour of the vector below.
    uint64 internal constant VECTOR_HOUR = 1_794_045_600;
    /// The root of the three receipts of the vector, from the TypeScript tree builder of Texel
    /// with the keccak-256 of viem (7 Nov 2026).
    bytes32 internal constant VECTOR_ROOT = 0xca9914e190fa409b6bf72f498cdcdbc5609b97c053a28ea9009d572349dcbe0d;

    address internal sealer = makeAddr("sealer");
    TexelReceipts internal receipts;

    function setUp() public {
        // 12:00 UTC: the hours of 10:00 and 11:00 have ended, the hour of 12:00 runs.
        vm.warp(VECTOR_HOUR + 2 * HOUR);
        receipts = new TexelReceipts(sealer);
    }

    function _seal(uint64 hour, bytes32 root, uint32 count) internal {
        vm.prank(sealer);
        receipts.seal(hour, root, count);
    }

    function _currentHour() internal view returns (uint64) {
        return uint64(block.timestamp - (block.timestamp % HOUR));
    }

    function _leaf(ReceiptFields memory r) internal pure returns (bytes32) {
        bytes memory encoded = abi.encode(
            uint8(1), r.hour, r.kind, r.item, r.width, r.height, r.duration, r.characters, r.credits, r.free, r.code
        );
        return keccak256(bytes.concat(keccak256(encoded)));
    }

    function _code(address wallet, uint64 time, bytes32 salt) internal pure returns (bytes32) {
        return keccak256(abi.encode(wallet, time, salt));
    }

    function _pair(bytes32 a, bytes32 b) internal pure returns (bytes32) {
        return a < b ? keccak256(abi.encode(a, b)) : keccak256(abi.encode(b, a));
    }

    /// The three receipts of the vector: a rental, a paid image, and a free image.
    function _vector() internal pure returns (ReceiptFields[3] memory list) {
        list[0] = ReceiptFields({
            hour: VECTOR_HOUR,
            kind: "rental",
            item: "rtx-pro-4000",
            width: 0,
            height: 0,
            duration: 1234,
            characters: 0,
            credits: 195_383,
            free: false,
            code: _code(
                address(0x1111111111111111111111111111111111111111),
                VECTOR_HOUR + 61,
                0xa1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1
            )
        });
        list[1] = ReceiptFields({
            hour: VECTOR_HOUR,
            kind: "image",
            item: "flux-schnell",
            width: 1024,
            height: 1024,
            duration: 0,
            characters: 0,
            credits: 4_194,
            free: false,
            code: _code(
                address(0x2222222222222222222222222222222222222222),
                VECTOR_HOUR + 1800,
                0xb2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2
            )
        });
        list[2] = ReceiptFields({
            hour: VECTOR_HOUR,
            kind: "image",
            item: "z-image-turbo",
            width: 1280,
            height: 720,
            duration: 0,
            characters: 0,
            credits: 0,
            free: true,
            code: _code(
                address(0x3333333333333333333333333333333333333333),
                VECTOR_HOUR + 3599,
                0xc3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3
            )
        });
    }

    function _vectorProofs() internal pure returns (bytes32[][3] memory proofs) {
        proofs[0] = new bytes32[](2);
        proofs[0][0] = 0x069704dd5397cb5ae64bb8c91b4e1081a11198e81fab503e4dd93d3a8e11a535;
        proofs[0][1] = 0xbf74bd5318cc2fdeb24241577a85a88159b43e43b2d9faf3e2e672e28f149008;
        proofs[1] = new bytes32[](1);
        proofs[1][0] = 0x8108ebbcfec3188ca8a6520b575be1491e0e0b596aaa2cfdc41fa7675808f4b9;
        proofs[2] = new bytes32[](2);
        proofs[2][0] = 0x8bc2b1ea8d5d1558405d2583da29114eb4223d7f2c14a09d3cd5d9ed892edcf7;
        proofs[2][1] = 0xbf74bd5318cc2fdeb24241577a85a88159b43e43b2d9faf3e2e672e28f149008;
    }

    function test_SealerIsTheAddressOfTheConstructor() public view {
        assertEq(receipts.sealer(), sealer);
    }

    function test_RevertWhen_SealerIsZero() public {
        vm.expectRevert(TexelReceipts.ZeroSealer.selector);
        new TexelReceipts(address(0));
    }

    function test_SealKeepsTheRootTheCountAndTheBlockTime() public {
        vm.expectEmit(true, false, false, true, address(receipts));
        emit Sealed(VECTOR_HOUR, VECTOR_ROOT, 3);
        _seal(VECTOR_HOUR, VECTOR_ROOT, 3);
        (bytes32 root, uint32 count, uint64 sealedAt) = receipts.seals(VECTOR_HOUR);
        assertEq(root, VECTOR_ROOT);
        assertEq(count, 3);
        assertEq(sealedAt, block.timestamp);
    }

    function test_AnHourWithNoReceiptSealsWithAZeroRoot() public {
        vm.expectEmit(true, false, false, true, address(receipts));
        emit Sealed(VECTOR_HOUR, bytes32(0), 0);
        _seal(VECTOR_HOUR, bytes32(0), 0);
        (bytes32 root, uint32 count, uint64 sealedAt) = receipts.seals(VECTOR_HOUR);
        assertEq(root, bytes32(0));
        assertEq(count, 0);
        assertEq(sealedAt, block.timestamp);
        assertFalse(receipts.verify(VECTOR_HOUR, bytes32(0), new bytes32[](0)));
    }

    function test_AnHourWithNoSealReadsZero() public view {
        (bytes32 root, uint32 count, uint64 sealedAt) = receipts.seals(VECTOR_HOUR);
        assertEq(root, bytes32(0));
        assertEq(count, 0);
        assertEq(sealedAt, 0);
    }

    function test_RevertWhen_TheCallerIsNotTheSealer() public {
        vm.expectRevert(TexelReceipts.NotSealer.selector);
        receipts.seal(VECTOR_HOUR, VECTOR_ROOT, 3);
    }

    function test_RevertWhen_TheHourIsNotTheStartOfAnHour() public {
        vm.expectRevert(abi.encodeWithSelector(TexelReceipts.NotAnHour.selector, VECTOR_HOUR + 1));
        _seal(VECTOR_HOUR + 1, VECTOR_ROOT, 3);
    }

    function test_RevertWhen_TheHourRunsStill() public {
        uint64 hour = _currentHour();
        vm.expectRevert(abi.encodeWithSelector(TexelReceipts.HourNotOver.selector, hour));
        _seal(hour, VECTOR_ROOT, 3);
    }

    function test_RevertWhen_TheHourIsInTheFuture() public {
        uint64 hour = _currentHour() + 5 * HOUR;
        vm.expectRevert(abi.encodeWithSelector(TexelReceipts.HourNotOver.selector, hour));
        _seal(hour, VECTOR_ROOT, 3);
    }

    function test_AnHourSealsFromItsLastSecondOn() public {
        uint64 hour = _currentHour();
        vm.warp(hour + HOUR - 1);
        vm.expectRevert(abi.encodeWithSelector(TexelReceipts.HourNotOver.selector, hour));
        _seal(hour, VECTOR_ROOT, 3);
        vm.warp(hour + HOUR);
        _seal(hour, VECTOR_ROOT, 3);
        (,, uint64 sealedAt) = receipts.seals(hour);
        assertEq(sealedAt, hour + HOUR);
    }

    function test_RevertWhen_TheHourIsSealedAlready() public {
        _seal(VECTOR_HOUR, VECTOR_ROOT, 3);
        vm.expectRevert(abi.encodeWithSelector(TexelReceipts.AlreadySealed.selector, VECTOR_HOUR));
        _seal(VECTOR_HOUR, VECTOR_ROOT, 3);
        vm.expectRevert(abi.encodeWithSelector(TexelReceipts.AlreadySealed.selector, VECTOR_HOUR));
        _seal(VECTOR_HOUR, keccak256("another root"), 4);
    }

    function test_RevertWhen_AnEmptyHourTakesARootLater() public {
        _seal(VECTOR_HOUR, bytes32(0), 0);
        vm.expectRevert(abi.encodeWithSelector(TexelReceipts.AlreadySealed.selector, VECTOR_HOUR));
        _seal(VECTOR_HOUR, VECTOR_ROOT, 3);
    }

    function test_RevertWhen_TheRootDoesNotFitTheCount() public {
        vm.expectRevert(TexelReceipts.RootDoesNotFitCount.selector);
        _seal(VECTOR_HOUR, VECTOR_ROOT, 0);
        vm.expectRevert(TexelReceipts.RootDoesNotFitCount.selector);
        _seal(VECTOR_HOUR, bytes32(0), 3);
    }

    function test_TheLeavesOfTheVectorFollowTheFormat() public pure {
        ReceiptFields[3] memory list = _vector();
        assertEq(_leaf(list[0]), 0x8bc2b1ea8d5d1558405d2583da29114eb4223d7f2c14a09d3cd5d9ed892edcf7);
        assertEq(_leaf(list[1]), 0xbf74bd5318cc2fdeb24241577a85a88159b43e43b2d9faf3e2e672e28f149008);
        assertEq(_leaf(list[2]), 0x069704dd5397cb5ae64bb8c91b4e1081a11198e81fab503e4dd93d3a8e11a535);
        assertEq(list[0].code, 0x3b98a4aa64ea04c8bbdacdb074e08622a71bd13e0fc19122d3a0d7c20626d576);
        assertEq(list[1].code, 0x5efef1c0442fc4654b8e5b9785407cb106b33c59a4aadc8746861dbdd843ee41);
        assertEq(list[2].code, 0x5490cb87dac2f0aae6ec704a2e0f503c0dd4d37232b58f764736771646b6d4f9);
    }

    function test_EveryReceiptOfTheVectorVerifies() public {
        _seal(VECTOR_HOUR, VECTOR_ROOT, 3);
        ReceiptFields[3] memory list = _vector();
        bytes32[][3] memory proofs = _vectorProofs();
        for (uint256 i = 0; i < 3; ++i) {
            assertTrue(receipts.verify(VECTOR_HOUR, _leaf(list[i]), proofs[i]));
        }
    }

    function test_AChangedReceiptDoesNotVerify() public {
        _seal(VECTOR_HOUR, VECTOR_ROOT, 3);
        ReceiptFields[3] memory list = _vector();
        bytes32[][3] memory proofs = _vectorProofs();
        list[1].credits = 1;
        assertFalse(receipts.verify(VECTOR_HOUR, _leaf(list[1]), proofs[1]));
        list[0].free = true;
        assertFalse(receipts.verify(VECTOR_HOUR, _leaf(list[0]), proofs[0]));
    }

    function test_AReceiptDoesNotVerifyWithAWrongProofOrHour() public {
        _seal(VECTOR_HOUR, VECTOR_ROOT, 3);
        ReceiptFields[3] memory list = _vector();
        bytes32[][3] memory proofs = _vectorProofs();
        bytes32 leaf = _leaf(list[0]);
        assertFalse(receipts.verify(VECTOR_HOUR, leaf, proofs[1]));
        assertFalse(receipts.verify(VECTOR_HOUR, leaf, new bytes32[](0)));
        assertFalse(receipts.verify(VECTOR_HOUR + HOUR, leaf, proofs[0]));
    }

    function test_AnHourWithNoSealVerifiesNothing() public view {
        ReceiptFields[3] memory list = _vector();
        bytes32[][3] memory proofs = _vectorProofs();
        assertFalse(receipts.verify(VECTOR_HOUR, _leaf(list[0]), proofs[0]));
    }

    function test_TheContractTakesNoMoney() public {
        vm.deal(address(this), 1 ether);
        (bool sent,) = address(receipts).call{value: 1 wei}("");
        assertFalse(sent);
        assertEq(address(receipts).balance, 0);
    }

    function testFuzz_AnyHourThatEndedSealsOnce(uint64 hoursAgo, bytes32 root, uint32 count) public {
        hoursAgo = uint64(bound(hoursAgo, 1, block.timestamp / HOUR));
        uint64 hour = _currentHour() - hoursAgo * HOUR;
        vm.assume(root != bytes32(0));
        count = uint32(bound(count, 1, type(uint32).max));
        _seal(hour, root, count);
        (bytes32 kept, uint32 keptCount, uint64 sealedAt) = receipts.seals(hour);
        assertEq(kept, root);
        assertEq(keptCount, count);
        assertEq(sealedAt, block.timestamp);
        vm.expectRevert(abi.encodeWithSelector(TexelReceipts.AlreadySealed.selector, hour));
        _seal(hour, root, count);
    }

    function testFuzz_RevertWhen_AnotherAddressSeals(address caller) public {
        vm.assume(caller != sealer);
        vm.prank(caller);
        vm.expectRevert(TexelReceipts.NotSealer.selector);
        receipts.seal(VECTOR_HOUR, VECTOR_ROOT, 3);
    }

    function testFuzz_RevertWhen_TheHourIsNoHourStart(uint64 hour) public {
        vm.assume(hour % HOUR != 0);
        vm.expectRevert(abi.encodeWithSelector(TexelReceipts.NotAnHour.selector, hour));
        _seal(hour, VECTOR_ROOT, 3);
    }

    function testFuzz_RevertWhen_TheHourHasNotEnded(uint64 hoursAhead) public {
        hoursAhead = uint64(bound(hoursAhead, 0, (type(uint64).max - block.timestamp) / HOUR - 1));
        uint64 hour = _currentHour() + hoursAhead * HOUR;
        vm.expectRevert(abi.encodeWithSelector(TexelReceipts.HourNotOver.selector, hour));
        _seal(hour, VECTOR_ROOT, 3);
    }

    function testFuzz_OneReceiptIsItsOwnRoot(bytes32 leaf, bytes32 other) public {
        vm.assume(leaf != bytes32(0) && other != leaf);
        _seal(VECTOR_HOUR, leaf, 1);
        assertTrue(receipts.verify(VECTOR_HOUR, leaf, new bytes32[](0)));
        assertFalse(receipts.verify(VECTOR_HOUR, other, new bytes32[](0)));
    }

    function testFuzz_TwoReceiptsProveEachOther(bytes32 a, bytes32 b) public {
        vm.assume(a != b);
        bytes32 root = _pair(a, b);
        _seal(VECTOR_HOUR, root, 2);
        bytes32[] memory proofOfA = new bytes32[](1);
        proofOfA[0] = b;
        bytes32[] memory proofOfB = new bytes32[](1);
        proofOfB[0] = a;
        assertTrue(receipts.verify(VECTOR_HOUR, a, proofOfA));
        assertTrue(receipts.verify(VECTOR_HOUR, b, proofOfB));
    }
}
