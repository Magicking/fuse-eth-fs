// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "forge-std/Test.sol";
import "../../../contracts/plugins/rpc_proxy/StorageReaderPlugin.sol";
import "../../../contracts/plugins/rpc_proxy/IRPCProxyPlugin.sol";
import "../../../contracts/IFileSystem.sol";

/**
 * @title DummyTarget
 * @dev Simple contract with known storage for testing
 */
contract DummyTarget {
    uint256 public value0 = 42;
    uint256 public value1 = type(uint256).max;
    address public value2 = address(0xdead);
}

contract StorageReaderPluginTest is Test {
    StorageReaderPlugin public plugin;
    DummyTarget public target;
    uint256 constant NUM_SLOTS = 5;

    function setUp() public {
        target = new DummyTarget();
        plugin = new StorageReaderPlugin(address(target), NUM_SLOTS);
    }

    // ========== isRPCProxy ==========

    function test_isRPCProxy() public view {
        assertTrue(plugin.isRPCProxy());
    }

    // ========== Constructor ==========

    function test_constructor() public view {
        assertEq(plugin.targetContract(), address(target));
        assertEq(plugin.numSlots(), NUM_SLOTS);
    }

    // ========== getRPCDescriptor ==========

    function test_getRPCDescriptor_slot0() public view {
        IRPCProxyPlugin.RPCDescriptor memory desc = plugin.getRPCDescriptor(0);
        assertEq(uint8(desc.callType), uint8(IRPCProxyPlugin.RPCCallType.STORAGE_AT));
        assertEq(desc.targetAddress, address(target));
        assertEq(desc.callData, abi.encode(uint256(0)));
        assertEq(desc.blockNumber, 0);
    }

    function test_getRPCDescriptor_slot3() public view {
        IRPCProxyPlugin.RPCDescriptor memory desc = plugin.getRPCDescriptor(3);
        assertEq(desc.callData, abi.encode(uint256(3)));
    }

    function test_getRPCDescriptor_reverts_out_of_range() public {
        vm.expectRevert("Slot out of range");
        plugin.getRPCDescriptor(NUM_SLOTS);
    }

    // ========== formatRPCResult ==========

    function test_formatRPCResult_simple_value() public view {
        bytes memory rawResult = abi.encode(uint256(1000));
        bytes memory formatted = plugin.formatRPCResult(0, rawResult);

        // Check that the output contains expected strings
        string memory output = string(formatted);
        assertTrue(_contains(output, "Storage Slot: 0"));
        assertTrue(_contains(output, "As uint256:   1000"));
    }

    function test_formatRPCResult_zero() public view {
        bytes memory rawResult = new bytes(32); // all zeros
        bytes memory formatted = plugin.formatRPCResult(0, rawResult);

        string memory output = string(formatted);
        assertTrue(_contains(output, "As uint256:   0"));
        assertTrue(_contains(output, "As int256:    0"));
    }

    function test_formatRPCResult_max_uint() public view {
        bytes memory rawResult = abi.encode(type(uint256).max);
        bytes memory formatted = plugin.formatRPCResult(1, rawResult);

        string memory output = string(formatted);
        assertTrue(_contains(output, "Storage Slot: 1"));
        // int256 of max uint256 is -1
        assertTrue(_contains(output, "As int256:    -1"));
    }

    function test_formatRPCResult_hex_output() public view {
        bytes memory rawResult = abi.encode(uint256(0xff));
        bytes memory formatted = plugin.formatRPCResult(0, rawResult);

        string memory output = string(formatted);
        // Should contain hex representation starting with 0x
        assertTrue(_contains(output, "Raw (hex):    0x"));
    }

    // ========== IFileSystem: getEntries ==========

    function test_getEntries() public view {
        uint256[] memory entries = plugin.getEntries();
        assertEq(entries.length, NUM_SLOTS);
        for (uint256 i = 0; i < NUM_SLOTS; i++) {
            assertEq(entries[i], i);
        }
    }

    // ========== IFileSystem: getEntryCount ==========

    function test_getEntryCount() public view {
        assertEq(plugin.getEntryCount(), NUM_SLOTS);
    }

    // ========== IFileSystem: getEntriesPaginated ==========

    function test_getEntriesPaginated() public view {
        uint256[] memory entries = plugin.getEntriesPaginated(1, 2);
        assertEq(entries.length, 2);
        assertEq(entries[0], 1);
        assertEq(entries[1], 2);
    }

    function test_getEntriesPaginated_overflow() public view {
        uint256[] memory entries = plugin.getEntriesPaginated(3, 10);
        assertEq(entries.length, 2); // only 2 remaining (slots 3, 4)
    }

    function test_getEntriesPaginated_out_of_range() public view {
        uint256[] memory entries = plugin.getEntriesPaginated(NUM_SLOTS, 1);
        assertEq(entries.length, 0);
    }

    // ========== IFileSystem: getEntry ==========

    function test_getEntry_valid() public view {
        (
            IFileSystem.EntryType entryType,
            address owner,
            bytes memory name,
            bytes memory body,
            uint256 timestamp,
            bool entryExists,
            uint256 fileSize,
            address directoryTarget
        ) = plugin.getEntry(2);

        assertEq(uint8(entryType), uint8(IFileSystem.EntryType.FILE));
        assertEq(owner, address(plugin));
        assertEq(string(name), "slot_2.txt");
        assertTrue(entryExists);
        assertEq(fileSize, 0); // dynamic
        assertEq(directoryTarget, address(0));
    }

    function test_getEntry_invalid() public view {
        (
            , , , , ,
            bool entryExists,
            ,
        ) = plugin.getEntry(NUM_SLOTS);

        assertFalse(entryExists);
    }

    // ========== IFileSystem: exists ==========

    function test_exists() public view {
        assertTrue(plugin.exists(0));
        assertTrue(plugin.exists(NUM_SLOTS - 1));
        assertFalse(plugin.exists(NUM_SLOTS));
    }

    // ========== IFileSystem: readFile returns empty ==========

    function test_readFile_returns_empty() public view {
        bytes memory result = plugin.readFile(0, 0, 0);
        assertEq(result.length, 0);
    }

    // ========== Write operations revert ==========

    function test_createFile_reverts() public {
        vm.expectRevert(StorageReaderPlugin.NotImplemented.selector);
        plugin.createFile("test", "body", 0);
    }

    function test_createDirectory_reverts() public {
        vm.expectRevert(StorageReaderPlugin.NotImplemented.selector);
        plugin.createDirectory("test", address(0));
    }

    function test_updateFile_reverts() public {
        vm.expectRevert(StorageReaderPlugin.NotImplemented.selector);
        plugin.updateFile(0, "body", 0);
    }

    function test_deleteEntry_reverts() public {
        vm.expectRevert(StorageReaderPlugin.NotImplemented.selector);
        plugin.deleteEntry(0);
    }

    function test_writeFile_reverts() public {
        vm.expectRevert(StorageReaderPlugin.NotImplemented.selector);
        plugin.writeFile(0, 0, "body");
    }

    // ========== Helper ==========

    function _contains(string memory haystack, string memory needle) internal pure returns (bool) {
        bytes memory h = bytes(haystack);
        bytes memory n = bytes(needle);
        if (n.length > h.length) return false;
        for (uint256 i = 0; i <= h.length - n.length; i++) {
            bool found = true;
            for (uint256 j = 0; j < n.length; j++) {
                if (h[i + j] != n[j]) {
                    found = false;
                    break;
                }
            }
            if (found) return true;
        }
        return false;
    }
}
