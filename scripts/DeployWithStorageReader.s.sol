// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Script, console} from "forge-std/Script.sol";
import {FileSystem} from "../contracts/FileSystem.sol";
import {IFileSystem} from "../contracts/IFileSystem.sol";
import {StorageReaderPlugin} from "../contracts/plugins/rpc_proxy/StorageReaderPlugin.sol";
import {IRPCProxyPlugin} from "../contracts/plugins/rpc_proxy/IRPCProxyPlugin.sol";
import {stdJson} from "forge-std/StdJson.sol";

/**
 * @title DeployWithStorageReader
 * @dev Deploys a FileSystem with a StorageReaderPlugin that inspects
 *      the FileSystem's own storage slots. Demonstrates the RPC proxy
 *      plugin pattern end-to-end.
 *
 * Usage:
 *   anvil                           # start local node
 *   forge script DeployWithStorageReader.s.sol \
 *       --rpc-url http://127.0.0.1:8545 \
 *       --broadcast
 *
 * Then mount and explore:
 *   python -m fuse_eth_fs.main /tmp/ethfs --foreground --debug
 *   ls   /tmp/ethfs/31337/<DEPLOYER>/storage_inspector/
 *   cat  /tmp/ethfs/31337/<DEPLOYER>/storage_inspector/slot_0.txt
 */
contract DeployWithStorageReader is Script {
    using stdJson for string;

    function run() external {
        console.log("=== DeployWithStorageReader ===");
        console.log("");

        vm.startBroadcast();

        // 1. Deploy the main FileSystem
        FileSystem fileSystem = new FileSystem();
        console.log("FileSystem deployed to:", address(fileSystem));

        // 2. Populate with some sample files so the storage is non-trivial
        fileSystem.createFile(
            bytes("README.md"),
            bytes("# Storage Inspector Demo\n\nThis filesystem has a StorageReaderPlugin attached."),
            0
        );
        fileSystem.createFile(
            bytes("hello.txt"),
            bytes("Hello from fuse-eth-fs!"),
            0
        );

        // 3. Deploy StorageReaderPlugin pointing at the FileSystem itself
        //    Reading 10 storage slots gives visibility into the filesystem's
        //    internal bookkeeping (entry map, directory targets, clusters, etc.)
        uint256 numSlots = 10;
        StorageReaderPlugin storageReader = new StorageReaderPlugin(
            address(fileSystem),
            numSlots
        );
        console.log("StorageReaderPlugin deployed to:", address(storageReader));
        console.log("  target:", address(fileSystem));
        console.log("  slots: ", numSlots);

        // 4. Verify the plugin identifies itself as an RPC proxy
        require(storageReader.isRPCProxy(), "StorageReaderPlugin must be an RPC proxy");

        // 5. Register it as a subdirectory in the main FileSystem
        fileSystem.createDirectory(bytes("storage_inspector"), address(storageReader));

        vm.stopBroadcast();

        // --- Display what was deployed ---

        console.log("");
        console.log("=== Filesystem Layout ===");

        uint256[] memory slots = fileSystem.getEntries();
        for (uint256 i = 0; i < slots.length; i++) {
            (
                IFileSystem.EntryType entryType,
                ,
                bytes memory name,
                ,
                ,
                bool entryExists,
                uint256 fileSize,
                address directoryTarget
            ) = fileSystem.getEntry(slots[i]);

            if (!entryExists) continue;

            if (entryType == IFileSystem.EntryType.FILE) {
                console.log(string(abi.encodePacked(
                    "  [FILE] ", string(name), " (", vm.toString(fileSize), " bytes)"
                )));
            } else if (entryType == IFileSystem.EntryType.DIRECTORY) {
                console.log(string(abi.encodePacked(
                    "  [DIR]  ", string(name), " -> ", vm.toString(directoryTarget)
                )));

                // List the plugin's virtual files
                if (directoryTarget != address(0)) {
                    try IFileSystem(directoryTarget).getEntries() returns (uint256[] memory subSlots) {
                        for (uint256 j = 0; j < subSlots.length && j < 5; j++) {
                            (,,bytes memory subName,,,,, ) = IFileSystem(directoryTarget).getEntry(subSlots[j]);
                            console.log(string(abi.encodePacked("    - ", string(subName))));
                        }
                        if (subSlots.length > 5) {
                            console.log(string(abi.encodePacked(
                                "    ... and ", vm.toString(subSlots.length - 5), " more"
                            )));
                        }
                    } catch {}
                }
            }
        }

        // --- Display a sample RPC descriptor ---

        console.log("");
        console.log("=== Sample RPC Descriptor (slot 0) ===");
        IRPCProxyPlugin.RPCDescriptor memory desc = storageReader.getRPCDescriptor(0);
        console.log("  callType:      ", uint256(desc.callType), "(STORAGE_AT)");
        console.log("  targetAddress: ", desc.targetAddress);
        console.log("  blockNumber:   ", desc.blockNumber, "(0 = latest)");

        // --- Write deployment.json ---

        uint256 chainId = block.chainid;
        uint256 timestamp = block.timestamp;

        string memory jsonKey = "deployment";
        jsonKey.serialize("address", address(fileSystem));
        jsonKey.serialize("storageReaderPlugin", address(storageReader));

        string memory chainIdStr = vm.toString(chainId);
        jsonKey.serialize("chainId", chainIdStr);

        string memory timestampStr = vm.toString(timestamp);
        string memory json = jsonKey.serialize("deployedAt", timestampStr);

        json.write("./deployment.json");

        console.log("");
        console.log("Deployment info saved to deployment.json");
        console.log("Chain ID:", chainId);
        console.log("");
        console.log("Next steps:");
        console.log("  python -m fuse_eth_fs.main /tmp/ethfs --foreground --debug");
        console.log("  ls /tmp/ethfs/", chainId, "/<YOUR_ADDRESS>/storage_inspector/");
    }
}
