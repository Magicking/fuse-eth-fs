// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import "../../contracts/FileSystem.sol";
import "../../contracts/IFileSystem.sol";

contract FileSystemTest is Test {
    FileSystem public fs;
    FileSystem public fs2; // For directory target testing
    FileSystem public fs3; // For nested directory testing
    address public user1;
    address public user2;
    
    // Storage slots will be auto-assigned starting from 0
    // We'll track them as we create entries
    uint256 slotFile1;
    uint256 slotFile2;
    uint256 slotFile3;
    uint256 slotDir1;
    uint256 slotDir2;
    uint256 slotDir3;

    function setUp() public {
        fs = new FileSystem();
        fs2 = new FileSystem();
        fs3 = new FileSystem();
        user1 = address(0x1);
        user2 = address(0x2);
    }

    function testCreateFile() public {
        vm.prank(user1);
        fs.createFile(bytes("test.txt"), bytes("Hello, World!"), 0);
        
        // Get the assigned slot (should be 0 for first entry)
        uint256[] memory entries = fs.getEntries();
        require(entries.length > 0, "Entry should be created");
        slotFile1 = entries[0];

        (
            IFileSystem.EntryType entryType,
            address owner,
            bytes memory name,
            bytes memory body,
            uint256 timestamp,
            bool entryExists,
            uint256 fileSize,
            address directoryTarget
        ) = fs.getEntry(slotFile1);

        assertTrue(entryExists);
        assertEq(uint(entryType), uint(IFileSystem.EntryType.FILE));
        assertEq(owner, user1);
        assertEq(string(name), "test.txt");
        assertEq(string(body), "Hello, World!");
        assertEq(fileSize, 13);
        assertEq(directoryTarget, address(0));
        assertGt(timestamp, 0);
    }

    function testCreateDirectory() public {
        vm.prank(user1);
        fs.createDirectory(address(fs2));
        
        // Get the assigned slot (should be 0 for first entry)
        uint256[] memory entries = fs.getEntries();
        require(entries.length > 0, "Entry should be created");
        slotDir1 = entries[0];

        (
            IFileSystem.EntryType entryType,
            address owner,
            bytes memory name,
            bytes memory body,
            ,
            bool entryExists,
            uint256 fileSize,
            address directoryTarget
        ) = fs.getEntry(slotDir1);

        assertTrue(entryExists);
        assertEq(uint(entryType), uint(IFileSystem.EntryType.DIRECTORY));
        assertEq(owner, user1);
        assertEq(name.length, 0);
        assertEq(body.length, 0);
        assertEq(fileSize, 0);
        assertEq(directoryTarget, address(fs2));
    }

    function testUpdateFile() public {
        vm.startPrank(user1);
        fs.createFile(bytes("test.txt"), bytes("Hello"), 0);
        uint256[] memory entries = fs.getEntries();
        slotFile1 = entries[0];
        fs.updateFile(slotFile1, bytes("World"), 0);
        vm.stopPrank();

        (, , , bytes memory body, , , , ) = fs.getEntry(slotFile1);
        assertEq(string(body), "World");
    }

    function testCannotCreateDuplicateFile() public {
        vm.startPrank(user1);
        fs.createFile(bytes("test1.txt"), bytes("Test"), 0);
        // Since slots are auto-assigned, we can't create a duplicate at the same slot
        // This test is no longer applicable - each createFile gets a new slot
        // Instead, test that we can create multiple files
        fs.createFile(bytes("test2.txt"), bytes("Another"), 0);
        uint256[] memory entries = fs.getEntries();
        assertEq(entries.length, 2);
        vm.stopPrank();
    }

    function testCannotCreateDuplicateDirectory() public {
        vm.startPrank(user1);
        fs.createDirectory(address(fs2));
        // Since slots are auto-assigned, we can't create a duplicate at the same slot
        // This test is no longer applicable - each createDirectory gets a new slot
        // Instead, test that we can create multiple directories
        fs.createDirectory(address(fs3));
        uint256[] memory entries = fs.getEntries();
        assertEq(entries.length, 2);
        vm.stopPrank();
    }

    function testCannotCreateDirectoryWithInvalidTarget() public {
        vm.startPrank(user1);
        vm.expectRevert("Invalid target address");
        fs.createDirectory(address(0));
        
        vm.expectRevert("Cannot point to self");
        fs.createDirectory(address(fs));
        vm.stopPrank();
    }

    function testDeleteFile() public {
        vm.startPrank(user1);
        fs.createFile(bytes("test.txt"), bytes("Test"), 0);
        uint256[] memory entries = fs.getEntries();
        slotFile1 = entries[0];
        fs.deleteEntry(slotFile1);
        vm.stopPrank();

        (, , , , , bool entryExists, , ) = fs.getEntry(slotFile1);
        assertFalse(entryExists);
    }

    function testDeleteRemovesFromEntryList() public {
        vm.startPrank(user1);
        fs.createFile(bytes("file1.txt"), bytes("1"), 0);
        fs.createFile(bytes("file2.txt"), bytes("2"), 0);
        fs.createFile(bytes("file3.txt"), bytes("3"), 0);
        
        uint256[] memory entriesBefore = fs.getEntries();
        assertEq(entriesBefore.length, 3);
        slotFile2 = entriesBefore[1]; // Get the middle slot
        
        fs.deleteEntry(slotFile2);
        
        uint256[] memory entriesAfter = fs.getEntries();
        assertEq(entriesAfter.length, 2);
        
        // Verify slotFile2 is not in the list
        bool found = false;
        for (uint i = 0; i < entriesAfter.length; i++) {
            if (entriesAfter[i] == slotFile2) {
                found = true;
                break;
            }
        }
        assertFalse(found, "Deleted file should not be in entries list");
        vm.stopPrank();
    }

    function testCannotDeleteNonExistentEntry() public {
        vm.prank(user1);
        vm.expectRevert("Entry does not exist");
        fs.deleteEntry(999);
    }

    function testOnlyOwnerCanUpdateFile() public {
        vm.prank(user1);
        fs.createFile(bytes("test.txt"), bytes("Test"), 0);
        uint256[] memory entries = fs.getEntries();
        slotFile1 = entries[0];

        vm.prank(user2);
        vm.expectRevert("Not owner");
        fs.updateFile(slotFile1, bytes("Hacked"), 0);
    }

    function testOnlyOwnerCanDeleteFile() public {
        vm.prank(user1);
        fs.createFile(bytes("test.txt"), bytes("Test"), 0);
        uint256[] memory entries = fs.getEntries();
        slotFile1 = entries[0];

        vm.prank(user2);
        vm.expectRevert("Not owner");
        fs.deleteEntry(slotFile1);
    }

    function testCannotUpdateNonExistentFile() public {
        vm.prank(user1);
        vm.expectRevert("Entry does not exist");
        fs.updateFile(999, bytes("Content"), 0);
    }

    function testCannotUpdateDirectory() public {
        vm.startPrank(user1);
        fs.createDirectory(address(fs2));
        uint256[] memory entries = fs.getEntries();
        slotDir1 = entries[0];
        
        vm.expectRevert("Not a file");
        fs.updateFile(slotDir1, bytes("Content"), 0);
        vm.stopPrank();
    }

    function testGetEntries() public {
        vm.startPrank(user1);
        fs.createFile(bytes("file1.txt"), bytes("1"), 0);
        fs.createFile(bytes("file2.txt"), bytes("2"), 0);
        fs.createDirectory(address(fs2));
        vm.stopPrank();

        uint256[] memory entries = fs.getEntries();
        assertEq(entries.length, 3);
    }

    function testExistsFunction() public {
        vm.prank(user1);
        fs.createFile(bytes("test.txt"), bytes("Test"), 0);
        uint256[] memory entries = fs.getEntries();
        slotFile1 = entries[0];

        assertTrue(fs.exists(slotFile1));
        assertFalse(fs.exists(999));
    }

    function testFileTimestamp() public {
        uint256 beforeCreate = block.timestamp;
        
        vm.prank(user1);
        fs.createFile(bytes("test.txt"), bytes("Test"), 0);
        uint256[] memory entries = fs.getEntries();
        slotFile1 = entries[0];
        
        (, , , , uint256 timestamp, , , ) = fs.getEntry(slotFile1);
        
        assertGe(timestamp, beforeCreate);
        assertLe(timestamp, block.timestamp);
    }

    function testUpdateTimestamp() public {
        vm.startPrank(user1);
        fs.createFile(bytes("test.txt"), bytes("Test"), 0);
        uint256[] memory entries = fs.getEntries();
        slotFile1 = entries[0];
        
        (, , , , uint256 timestamp1, , , ) = fs.getEntry(slotFile1);
        
        vm.warp(block.timestamp + 100);
        fs.updateFile(slotFile1, bytes("Updated"), 0);
        
        (, , , , uint256 timestamp2, , , ) = fs.getEntry(slotFile1);
        vm.stopPrank();
        
        assertGt(timestamp2, timestamp1);
    }
    
    function testCreateFileWithOffset() public {
        vm.startPrank(user1);
        fs.createFile(bytes("test.txt"), bytes("World"), 6);
        uint256[] memory entries = fs.getEntries();
        slotFile1 = entries[0];
        
        bytes memory body = fs.readFile(slotFile1, 0, 0);
        assertEq(body.length, 11); // 6 bytes padding + 5 bytes "World"
        assertEq(string(body), string(abi.encodePacked(bytes6(0), "World")));
        vm.stopPrank();
    }
    
    function testWriteFileWithOffset() public {
        vm.startPrank(user1);
        fs.createFile(bytes("test.txt"), bytes("Hello"), 0);
        uint256[] memory entries = fs.getEntries();
        slotFile1 = entries[0];
        fs.writeFile(slotFile1, 5, bytes(" World")); // Write space + World at offset 5
        
        bytes memory body = fs.readFile(slotFile1, 0, 0);
        assertEq(string(body), "Hello World");
        assertEq(body.length, 11);
        vm.stopPrank();
    }
    
    function testWriteFileWithGap() public {
        vm.startPrank(user1);
        fs.createFile(bytes("test.txt"), bytes("Hello"), 0);
        uint256[] memory entries = fs.getEntries();
        slotFile1 = entries[0];
        fs.writeFile(slotFile1, 6, bytes("World")); // Write at offset 6, leaving gap at position 5
        
        bytes memory body = fs.readFile(slotFile1, 0, 0);
        assertEq(body.length, 11); // 5 (Hello) + 1 (null) + 5 (World)
        assertEq(body[5], 0x00); // Position 5 should be null byte
        // Verify "Hello" and "World" parts
        bytes memory hello = fs.readFile(slotFile1, 0, 5);
        bytes memory world = fs.readFile(slotFile1, 6, 5);
        assertEq(string(hello), "Hello");
        assertEq(string(world), "World");
        vm.stopPrank();
    }
    
    function testReadFileWithOffset() public {
        vm.startPrank(user1);
        fs.createFile(bytes("test.txt"), bytes("Hello, World!"), 0);
        uint256[] memory entries = fs.getEntries();
        slotFile1 = entries[0];
        
        bytes memory body = fs.readFile(slotFile1, 7, 5);
        assertEq(string(body), "World");
        vm.stopPrank();
    }
    
    function testDirectoryPointsToFileSystem() public {
        vm.startPrank(user1);
        // Create a directory pointing to fs2
        fs.createDirectory(address(fs2));
        uint256[] memory entries = fs.getEntries();
        slotDir1 = entries[0];
        
        // Create a file in fs2
        fs2.createFile(bytes("file.txt"), bytes("Content in fs2"), 0);
        uint256[] memory entries2 = fs2.getEntries();
        slotFile1 = entries2[0];
        
        // Get directory entry
        (, , , , , , , address target) = fs.getEntry(slotDir1);
        assertEq(target, address(fs2));
        
        // Verify we can access fs2 through the directory
        assertTrue(fs2.exists(slotFile1));
        vm.stopPrank();
    }
    
    function testReadCluster() public {
        vm.startPrank(user1);
        fs.createFile(bytes("test.txt"), bytes("Hello, World!"), 0);
        uint256[] memory entries = fs.getEntries();
        slotFile1 = entries[0];
        
        // Read first cluster
        uint256 cluster0 = fs.readCluster(slotFile1, 0);
        assertGt(cluster0, 0);
        
        // Read second cluster (should be empty or partial)
        uint256 cluster1 = fs.readCluster(slotFile1, 1);
        // cluster1 might be 0 or have partial data
        vm.stopPrank();
    }
    
    function testMultipleStorageSlots() public {
        vm.startPrank(user1);
        // Create files (slots will be auto-assigned sequentially starting from 0)
        fs.createFile(bytes("file1.txt"), bytes("File 1"), 0);
        fs.createFile(bytes("file2.txt"), bytes("File 2"), 0);
        fs.createFile(bytes("file3.txt"), bytes("File 3"), 0);
        
        uint256[] memory entries = fs.getEntries();
        assertEq(entries.length, 3);
        
        // Verify each file exists (slots should be 0, 1, 2)
        assertTrue(fs.exists(entries[0]));
        assertTrue(fs.exists(entries[1]));
        assertTrue(fs.exists(entries[2]));
        
        // Verify body
        bytes memory body0 = fs.readFile(entries[0], 0, 0);
        assertEq(string(body0), "File 1");
        vm.stopPrank();
    }
    
    function testStorageSlotIsolation() public {
        vm.startPrank(user1);
        // Create files in different filesystems (both will get slot 0)
        fs.createFile(bytes("file.txt"), bytes("Content in fs"), 0);
        fs2.createFile(bytes("file.txt"), bytes("Content in fs2"), 0);
        
        uint256[] memory entries1 = fs.getEntries();
        uint256[] memory entries2 = fs2.getEntries();
        slotFile1 = entries1[0];
        slotFile2 = entries2[0];
        
        // Verify isolation - each filesystem has its own slot 0
        bytes memory body1 = fs.readFile(slotFile1, 0, 0);
        bytes memory body2 = fs2.readFile(slotFile2, 0, 0);
        
        assertEq(string(body1), "Content in fs");
        assertEq(string(body2), "Content in fs2");
        vm.stopPrank();
    }
    
    function testRecursiveDisplay() public {
        // Create additional filesystems for nested directories
        FileSystem publicDir = new FileSystem();
        FileSystem privateDir = new FileSystem();
        FileSystem docsDir = new FileSystem();
        FileSystem imagesDir = new FileSystem();
        
        vm.startPrank(user1);
        
        // Create files in root
        fs.createFile(bytes("README.md"), bytes("# Project README\n\nThis is a sample filesystem project.\n"), 0);
        fs.createFile(bytes("LICENSE"), bytes("MIT License\n\nCopyright (c) 2024\n"), 0);
        fs.createFile(bytes("config.txt"), bytes("debug=true\nport=8080\nhost=localhost\n"), 0);
        
        // Create directories in root
        fs.createDirectory(address(publicDir));
        fs.createDirectory(address(privateDir));
        
        // Create files in public directory
        publicDir.createFile(bytes("index.html"), bytes("<!DOCTYPE html>\n<html>\n<head><title>Home</title></head>\n<body><h1>Welcome</h1></body>\n</html>\n"), 0);
        publicDir.createFile(bytes("style.css"), bytes("body {\n  font-family: Arial, sans-serif;\n  margin: 20px;\n}\n"), 0);
        publicDir.createDirectory(address(docsDir));
        
        // Create files in docs subdirectory
        docsDir.createFile(bytes("api.md"), bytes("# API Documentation\n\n## Endpoints\n- GET /api/users\n- POST /api/users\n"), 0);
        docsDir.createFile(bytes("guide.md"), bytes("# User Guide\n\n## Getting Started\n1. Install dependencies\n2. Run the application\n"), 0);
        
        // Create files in private directory
        privateDir.createFile(bytes("secrets.txt"), bytes("api_key=secret123\npassword=admin\n"), 0);
        privateDir.createDirectory(address(imagesDir));
        
        // Create files in images subdirectory
        imagesDir.createFile(bytes("logo.png"), bytes("PNG_IMAGE_DATA_HERE"), 0);
        imagesDir.createFile(bytes("banner.jpg"), bytes("JPEG_IMAGE_DATA_HERE"), 0);
        
        vm.stopPrank();
        
        // Display recursively
        console.log("\n=== Recursive File System Display ===");
        displayRecursive(fs, "", 0);
        
        // Verify structure
        uint256[] memory rootEntries = fs.getEntries();
        assertEq(rootEntries.length, 5); // 3 files + 2 directories
        
        uint256[] memory publicEntries = publicDir.getEntries();
        assertEq(publicEntries.length, 3); // 2 files + 1 directory
        
        uint256[] memory docsEntries = docsDir.getEntries();
        assertEq(docsEntries.length, 2); // 2 files
        
        uint256[] memory privateEntries = privateDir.getEntries();
        assertEq(privateEntries.length, 2); // 1 file + 1 directory
        
        uint256[] memory imagesEntries = imagesDir.getEntries();
        assertEq(imagesEntries.length, 2); // 2 files
    }
    
    function displayRecursive(FileSystem filesystem, string memory prefix, uint256 depth) internal view {
        uint256[] memory entries = filesystem.getEntries();
        
        for (uint256 i = 0; i < entries.length; i++) {
            uint256 slot = entries[i];
            (
                IFileSystem.EntryType entryType,
                ,
                bytes memory name,
                bytes memory body,
                ,
                bool entryExists,
                uint256 fileSize,
                address directoryTarget
            ) = filesystem.getEntry(slot);
            
            if (!entryExists) continue;
            
            // Create indentation based on depth
            string memory indent = "";
            for (uint256 j = 0; j < depth; j++) {
                indent = string(abi.encodePacked(indent, "  "));
            }
            
            if (entryType == IFileSystem.EntryType.FILE) {
                string memory fileName = string(name);
                console.log(string(abi.encodePacked(prefix, indent, "[FILE] ", fileName)));
                console.log(string(abi.encodePacked("      size: ", vm.toString(fileSize), ", slot: ", vm.toString(slot))));
                console.log(string(abi.encodePacked("      content: ", string(body))));
            } else if (entryType == IFileSystem.EntryType.DIRECTORY) {
                console.log(string(abi.encodePacked(prefix, indent, "[DIR]  slot: ", vm.toString(slot))));
                
                // Recursively display directory contents
                FileSystem targetFs = FileSystem(directoryTarget);
                displayRecursive(targetFs, prefix, depth + 1);
            }
        }
    }
}
