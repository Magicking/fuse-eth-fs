// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IFileSystem} from "../../IFileSystem.sol";
import {IRPCProxyPlugin} from "./IRPCProxyPlugin.sol";
import "@openzeppelin/contracts/utils/Strings.sol";

/**
 * @title StorageReaderPlugin
 * @dev RPC proxy plugin that reads N storage slots from a target contract.
 * Each slot i maps to a file "slot_{i}.txt".
 */
contract StorageReaderPlugin is IRPCProxyPlugin {
    using Strings for uint256;

    address public immutable targetContract;
    uint256 public immutable numSlots;

    error NotImplemented();

    constructor(address _targetContract, uint256 _numSlots) {
        targetContract = _targetContract;
        numSlots = _numSlots;
    }

    // ============ IRPCProxyPlugin Implementation ============

    function isRPCProxy() external pure override returns (bool) {
        return true;
    }

    function getRPCDescriptor(uint256 storageSlot)
        external view override returns (RPCDescriptor memory descriptor)
    {
        require(storageSlot < numSlots, "Slot out of range");
        descriptor = RPCDescriptor({
            callType: RPCCallType.STORAGE_AT,
            targetAddress: targetContract,
            callData: abi.encode(storageSlot),
            blockNumber: 0 // latest
        });
    }

    function formatRPCResult(uint256 storageSlot, bytes memory rpcResult)
        external pure override returns (bytes memory formattedContent)
    {
        // Decode the raw 32-byte storage value
        bytes32 rawValue;
        if (rpcResult.length >= 32) {
            rawValue = bytes32(rpcResult);
        } else {
            // Pad shorter results
            bytes memory padded = new bytes(32);
            for (uint256 i = 0; i < rpcResult.length; i++) {
                padded[32 - rpcResult.length + i] = rpcResult[i];
            }
            rawValue = bytes32(padded);
        }

        uint256 uintValue = uint256(rawValue);
        int256 intValue = int256(uintValue);

        // Build human-readable output
        formattedContent = abi.encodePacked(
            "Storage Slot: ", storageSlot.toString(), "\n",
            "Raw (hex):    ", _toHexString(rawValue), "\n",
            "As uint256:   ", uintValue.toString(), "\n",
            "As int256:    ", _toInt256String(intValue), "\n"
        );
    }

    // ============ IFileSystem Implementation ============

    function getEntry(uint256 storageSlot)
        external view override returns (
            EntryType entryType,
            address owner,
            bytes memory name,
            bytes memory body,
            uint256 timestamp,
            bool entryExists,
            uint256 fileSize,
            address directoryTarget
        )
    {
        if (storageSlot >= numSlots) {
            return (EntryType.FILE, address(0), "", "", 0, false, 0, address(0));
        }

        entryType = EntryType.FILE;
        owner = address(this);
        name = bytes(string(abi.encodePacked("slot_", storageSlot.toString(), ".txt")));
        body = "";
        timestamp = block.timestamp;
        entryExists = true;
        fileSize = 0; // Dynamic, determined by RPC proxy flow
        directoryTarget = address(0);
    }

    function getEntries() external view override returns (uint256[] memory) {
        uint256[] memory entries = new uint256[](numSlots);
        for (uint256 i = 0; i < numSlots; i++) {
            entries[i] = i;
        }
        return entries;
    }

    function getEntryCount() external view override returns (uint256) {
        return numSlots;
    }

    function getEntriesPaginated(uint256 offset, uint256 limit)
        external view override returns (uint256[] memory)
    {
        if (offset >= numSlots) {
            return new uint256[](0);
        }

        uint256 remaining = numSlots - offset;
        uint256 count = limit < remaining ? limit : remaining;
        uint256[] memory entries = new uint256[](count);

        for (uint256 i = 0; i < count; i++) {
            entries[i] = offset + i;
        }
        return entries;
    }

    function exists(uint256 storageSlot) external view override returns (bool) {
        return storageSlot < numSlots;
    }

    function readFile(uint256, uint256, uint256)
        external pure override returns (bytes memory)
    {
        // RPC proxy plugins don't serve content via readFile.
        // The Python layer uses getRPCDescriptor + formatRPCResult instead.
        return "";
    }

    function readCluster(uint256, uint256)
        external pure override returns (uint256)
    {
        return 0;
    }

    function createFile(bytes memory, bytes memory, uint256) external pure override {
        revert NotImplemented();
    }

    function createDirectory(bytes memory, address) external pure override {
        revert NotImplemented();
    }

    function updateFile(uint256, bytes memory, uint256) external pure override {
        revert NotImplemented();
    }

    function deleteEntry(uint256) external pure override {
        revert NotImplemented();
    }

    function writeFile(uint256, uint256, bytes memory) external pure override {
        revert NotImplemented();
    }

    // ============ Internal Helpers ============

    function _toHexString(bytes32 value) internal pure returns (string memory) {
        bytes memory hexChars = "0123456789abcdef";
        bytes memory result = new bytes(66); // "0x" + 64 hex chars
        result[0] = "0";
        result[1] = "x";
        for (uint256 i = 0; i < 32; i++) {
            result[2 + i * 2] = hexChars[uint8(value[i]) >> 4];
            result[3 + i * 2] = hexChars[uint8(value[i]) & 0x0f];
        }
        return string(result);
    }

    function _toInt256String(int256 value) internal pure returns (string memory) {
        if (value >= 0) {
            return uint256(value).toString();
        }
        return string(abi.encodePacked("-", uint256(-value).toString()));
    }
}
