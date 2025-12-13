// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Script, console} from "forge-std/Script.sol";
import {FileSystem} from "../contracts/FileSystem.sol";
import {IFileSystem} from "../contracts/IFileSystem.sol";
import {stdJson} from "forge-std/StdJson.sol";

contract Deploy is Script {
    using stdJson for string;

    function populateFileSystem(FileSystem fileSystemAddress) public {
        FileSystem fileSystem = fileSystemAddress;
        
        // Create a subdirectory filesystem
        FileSystem subDir = new FileSystem();
        
        // Create files with name, body, and offset
        fileSystem.createFile(bytes("README.md"), bytes("# Project README\n\nWelcome to the filesystem!"), 0);
        fileSystem.createFile(bytes("config.txt"), bytes("debug=true\nport=8080\n"), 0);
        
        // Create a directory pointing to the subdirectory
        fileSystem.createDirectory(address(subDir));
        
        // Create a file in the subdirectory
        subDir.createFile(bytes("nested.txt"), bytes("This is a nested file"), 0);
    }

    function displayFileSystem(IFileSystem fileSystem, string memory prefix) public view {
        uint256[] memory slots = fileSystem.getEntries();
        
        if (slots.length == 0) {
            console.log(string(abi.encodePacked(prefix, "(empty)")));
            return;
        }
        
        for (uint256 i = 0; i < slots.length; i++) {
            (
                IFileSystem.EntryType entryType,
                address owner,
                bytes memory name,
                bytes memory body,
                uint256 timestamp,
                bool entryExists,
                uint256 fileSize,
                address directoryTarget
            ) = fileSystem.getEntry(slots[i]);
            
            if (!entryExists) continue;
            
            if (entryType == IFileSystem.EntryType.FILE) {
                string memory fileName = string(name);
                console.log(string(abi.encodePacked(prefix, "[FILE] ", fileName, " (", vm.toString(fileSize), " bytes)")));
                
                // Display file content preview (first 80 bytes)
                if (body.length > 0) {
                    uint256 previewLength = body.length > 80 ? 80 : body.length;
                    bytes memory preview = new bytes(previewLength);
                    for (uint256 j = 0; j < previewLength; j++) {
                        preview[j] = body[j];
                    }
                    string memory previewStr = string(preview);
                    console.log(string(abi.encodePacked(prefix, "  Content: ", previewStr)));
                }
            } else if (entryType == IFileSystem.EntryType.DIRECTORY) {
                console.log(string(abi.encodePacked(prefix, "[DIR]  -> ", vm.toString(directoryTarget))));
                
                // Recursively display subdirectory if it's a valid IFileSystem
                if (directoryTarget != address(0)) {
                    try IFileSystem(directoryTarget).getEntries() returns (uint256[] memory) {
                        string memory newPrefix = string(abi.encodePacked(prefix, "  "));
                        displayFileSystem(IFileSystem(directoryTarget), newPrefix);
                    } catch {
                        console.log(string(abi.encodePacked(prefix, "  (invalid directory target)")));
                    }
                }
            }
        }
    }

    function run() external {
        console.log("Deploying FileSystem contract...");

        vm.startBroadcast();
        // Deploy the contract
        FileSystem fileSystem = new FileSystem();
        populateFileSystem(FileSystem(fileSystem));
        vm.stopBroadcast();
        address deployedAddress = address(fileSystem);
        
        console.log("FileSystem deployed to:", deployedAddress);

        // Get chain ID
        uint256 chainId = block.chainid;
        console.log("Chain ID:", chainId);

        // Get deployment timestamp
        uint256 timestamp = block.timestamp;

        // Create JSON object - serialize each field
        // The jsonKey "deployment" identifies the root object
        string memory jsonKey = "deployment";
        jsonKey.serialize("address", deployedAddress);
        
        // Convert chainId to string to match original format
        string memory chainIdStr = vm.toString(chainId);
        jsonKey.serialize("chainId", chainIdStr);
        
        // Convert timestamp to string (Unix timestamp as string)
        // Note: Original script used ISO string format, but Solidity doesn't have easy date formatting
        // Writing as Unix timestamp string - Python client can convert to ISO if needed
        string memory timestampStr = vm.toString(timestamp);
        string memory json = jsonKey.serialize("deployedAt", timestampStr);

        // Write to deployment.json
        json.write("./deployment.json");

        console.log("Deployment info saved to deployment.json");
        console.log("Address:", deployedAddress);
        console.log("Chain ID:", chainId);
        console.log("Timestamp:", timestamp);
        
        // Display filesystem content
        console.log("");
        console.log("=== Filesystem Content ===");
        displayFileSystem(IFileSystem(deployedAddress), "");
        console.log("==========================");
        console.log("");
    }
}

