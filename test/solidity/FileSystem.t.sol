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
    
    // Storage slot constants for testing
    uint256 constant SLOT_FILE1 = 1;
    uint256 constant SLOT_FILE2 = 2;
    uint256 constant SLOT_FILE3 = 3;
    uint256 constant SLOT_DIR1 = 10;
    uint256 constant SLOT_DIR2 = 11;
    uint256 constant SLOT_DIR3 = 12;

    function setUp() public {
        fs = new FileSystem();
        fs2 = new FileSystem();
        fs3 = new FileSystem();
        user1 = address(0x1);
        user2 = address(0x2);
    }

    function testCreateFile() public {
        vm.prank(user1);
        fs.createFile(SLOT_FILE1, bytes("Hello, World!"), 0);

        (
            IFileSystem.EntryType entryType,
            address owner,
            bytes memory content,
            uint256 timestamp,
            bool entryExists,
            uint256 fileSize,
            address directoryTarget
        ) = fs.getEntry(SLOT_FILE1);

        assertTrue(entryExists);
        assertEq(uint(entryType), uint(IFileSystem.EntryType.FILE));
        assertEq(owner, user1);
        assertEq(string(content), "Hello, World!");
        assertEq(fileSize, 13);
        assertEq(directoryTarget, address(0));
        assertGt(timestamp, 0);
    }

    function testCreateDirectory() public {
        vm.prank(user1);
        fs.createDirectory(SLOT_DIR1, address(fs2));

        (
            IFileSystem.EntryType entryType,
            address owner,
            bytes memory content,
            ,
            bool entryExists,
            uint256 fileSize,
            address directoryTarget
        ) = fs.getEntry(SLOT_DIR1);

        assertTrue(entryExists);
        assertEq(uint(entryType), uint(IFileSystem.EntryType.DIRECTORY));
        assertEq(owner, user1);
        assertEq(content.length, 0);
        assertEq(fileSize, 0);
        assertEq(directoryTarget, address(fs2));
    }

    function testUpdateFile() public {
        vm.startPrank(user1);
        fs.createFile(SLOT_FILE1, bytes("Hello"), 0);
        fs.updateFile(SLOT_FILE1, bytes("World"), 0);
        vm.stopPrank();

        (, , bytes memory content, , , , ) = fs.getEntry(SLOT_FILE1);
        assertEq(string(content), "World");
    }

    function testCannotCreateDuplicateFile() public {
        vm.startPrank(user1);
        fs.createFile(SLOT_FILE1, bytes("Test"), 0);
        
        vm.expectRevert("Entry already exists");
        fs.createFile(SLOT_FILE1, bytes("Duplicate"), 0);
        vm.stopPrank();
    }

    function testCannotCreateDuplicateDirectory() public {
        vm.startPrank(user1);
        fs.createDirectory(SLOT_DIR1, address(fs2));
        
        vm.expectRevert("Entry already exists");
        fs.createDirectory(SLOT_DIR1, address(fs2));
        vm.stopPrank();
    }

    function testCannotCreateDirectoryWithInvalidTarget() public {
        vm.startPrank(user1);
        vm.expectRevert("Invalid target address");
        fs.createDirectory(SLOT_DIR1, address(0));
        
        vm.expectRevert("Cannot point to self");
        fs.createDirectory(SLOT_DIR2, address(fs));
        vm.stopPrank();
    }

    function testDeleteFile() public {
        vm.startPrank(user1);
        fs.createFile(SLOT_FILE1, bytes("Test"), 0);
        fs.deleteEntry(SLOT_FILE1);
        vm.stopPrank();

        (, , , , bool entryExists, , ) = fs.getEntry(SLOT_FILE1);
        assertFalse(entryExists);
    }

    function testDeleteRemovesFromEntryList() public {
        vm.startPrank(user1);
        fs.createFile(SLOT_FILE1, bytes("1"), 0);
        fs.createFile(SLOT_FILE2, bytes("2"), 0);
        fs.createFile(SLOT_FILE3, bytes("3"), 0);
        
        uint256[] memory entriesBefore = fs.getEntries();
        assertEq(entriesBefore.length, 3);
        
        fs.deleteEntry(SLOT_FILE2);
        
        uint256[] memory entriesAfter = fs.getEntries();
        assertEq(entriesAfter.length, 2);
        
        // Verify SLOT_FILE2 is not in the list
        bool found = false;
        for (uint i = 0; i < entriesAfter.length; i++) {
            if (entriesAfter[i] == SLOT_FILE2) {
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
        fs.createFile(SLOT_FILE1, bytes("Test"), 0);

        vm.prank(user2);
        vm.expectRevert("Not owner");
        fs.updateFile(SLOT_FILE1, bytes("Hacked"), 0);
    }

    function testOnlyOwnerCanDeleteFile() public {
        vm.prank(user1);
        fs.createFile(SLOT_FILE1, bytes("Test"), 0);

        vm.prank(user2);
        vm.expectRevert("Not owner");
        fs.deleteEntry(SLOT_FILE1);
    }

    function testCannotUpdateNonExistentFile() public {
        vm.prank(user1);
        vm.expectRevert("Entry does not exist");
        fs.updateFile(999, bytes("Content"), 0);
    }

    function testCannotUpdateDirectory() public {
        vm.startPrank(user1);
        fs.createDirectory(SLOT_DIR1, address(fs2));
        
        vm.expectRevert("Not a file");
        fs.updateFile(SLOT_DIR1, bytes("Content"), 0);
        vm.stopPrank();
    }

    function testGetEntries() public {
        vm.startPrank(user1);
        fs.createFile(SLOT_FILE1, bytes("1"), 0);
        fs.createFile(SLOT_FILE2, bytes("2"), 0);
        fs.createDirectory(SLOT_DIR1, address(fs2));
        vm.stopPrank();

        uint256[] memory entries = fs.getEntries();
        assertEq(entries.length, 3);
    }

    function testExistsFunction() public {
        vm.prank(user1);
        fs.createFile(SLOT_FILE1, bytes("Test"), 0);

        assertTrue(fs.exists(SLOT_FILE1));
        assertFalse(fs.exists(999));
    }

    function testFileTimestamp() public {
        uint256 beforeCreate = block.timestamp;
        
        vm.prank(user1);
        fs.createFile(SLOT_FILE1, bytes("Test"), 0);
        
        (, , , uint256 timestamp, , , ) = fs.getEntry(SLOT_FILE1);
        
        assertGe(timestamp, beforeCreate);
        assertLe(timestamp, block.timestamp);
    }

    function testUpdateTimestamp() public {
        vm.startPrank(user1);
        fs.createFile(SLOT_FILE1, bytes("Test"), 0);
        
        (, , , uint256 timestamp1, , , ) = fs.getEntry(SLOT_FILE1);
        
        vm.warp(block.timestamp + 100);
        fs.updateFile(SLOT_FILE1, bytes("Updated"), 0);
        
        (, , , uint256 timestamp2, , , ) = fs.getEntry(SLOT_FILE1);
        vm.stopPrank();
        
        assertGt(timestamp2, timestamp1);
    }
    
    function testCreateFileWithOffset() public {
        vm.startPrank(user1);
        fs.createFile(SLOT_FILE1, bytes("World"), 6);
        
        bytes memory content = fs.readFile(SLOT_FILE1, 0, 0);
        assertEq(content.length, 11); // 6 bytes padding + 5 bytes "World"
        assertEq(string(content), string(abi.encodePacked(bytes6(0), "World")));
        vm.stopPrank();
    }
    
    function testWriteFileWithOffset() public {
        vm.startPrank(user1);
        fs.createFile(SLOT_FILE1, bytes("Hello"), 0);
        fs.writeFile(SLOT_FILE1, 5, bytes(" World")); // Write space + World at offset 5
        
        bytes memory content = fs.readFile(SLOT_FILE1, 0, 0);
        assertEq(string(content), "Hello World");
        assertEq(content.length, 11);
        vm.stopPrank();
    }
    
    function testWriteFileWithGap() public {
        vm.startPrank(user1);
        fs.createFile(SLOT_FILE1, bytes("Hello"), 0);
        fs.writeFile(SLOT_FILE1, 6, bytes("World")); // Write at offset 6, leaving gap at position 5
        
        bytes memory content = fs.readFile(SLOT_FILE1, 0, 0);
        assertEq(content.length, 11); // 5 (Hello) + 1 (null) + 5 (World)
        assertEq(content[5], 0x00); // Position 5 should be null byte
        // Verify "Hello" and "World" parts
        bytes memory hello = fs.readFile(SLOT_FILE1, 0, 5);
        bytes memory world = fs.readFile(SLOT_FILE1, 6, 5);
        assertEq(string(hello), "Hello");
        assertEq(string(world), "World");
        vm.stopPrank();
    }
    
    function testReadFileWithOffset() public {
        vm.startPrank(user1);
        fs.createFile(SLOT_FILE1, bytes("Hello, World!"), 0);
        
        bytes memory content = fs.readFile(SLOT_FILE1, 7, 5);
        assertEq(string(content), "World");
        vm.stopPrank();
    }
    
    function testDirectoryPointsToFileSystem() public {
        vm.startPrank(user1);
        // Create a directory pointing to fs2
        fs.createDirectory(SLOT_DIR1, address(fs2));
        
        // Create a file in fs2
        fs2.createFile(SLOT_FILE1, bytes("Content in fs2"), 0);
        
        // Get directory entry
        (, , , , , , address target) = fs.getEntry(SLOT_DIR1);
        assertEq(target, address(fs2));
        
        // Verify we can access fs2 through the directory
        assertTrue(fs2.exists(SLOT_FILE1));
        vm.stopPrank();
    }
    
    function testReadCluster() public {
        vm.startPrank(user1);
        fs.createFile(SLOT_FILE1, bytes("Hello, World!"), 0);
        
        // Read first cluster
        uint256 cluster0 = fs.readCluster(SLOT_FILE1, 0);
        assertGt(cluster0, 0);
        
        // Read second cluster (should be empty or partial)
        uint256 cluster1 = fs.readCluster(SLOT_FILE1, 1);
        // cluster1 might be 0 or have partial data
        vm.stopPrank();
    }
    
    function testMultipleStorageSlots() public {
        vm.startPrank(user1);
        // Create files at different storage slots
        fs.createFile(100, bytes("File at slot 100"), 0);
        fs.createFile(200, bytes("File at slot 200"), 0);
        fs.createFile(300, bytes("File at slot 300"), 0);
        
        uint256[] memory entries = fs.getEntries();
        assertEq(entries.length, 3);
        
        // Verify each file exists
        assertTrue(fs.exists(100));
        assertTrue(fs.exists(200));
        assertTrue(fs.exists(300));
        
        // Verify content
        bytes memory content100 = fs.readFile(100, 0, 0);
        assertEq(string(content100), "File at slot 100");
        vm.stopPrank();
    }
    
    function testStorageSlotIsolation() public {
        vm.startPrank(user1);
        // Create files at same logical slot but different filesystems
        fs.createFile(SLOT_FILE1, bytes("Content in fs"), 0);
        fs2.createFile(SLOT_FILE1, bytes("Content in fs2"), 0);
        
        // Verify isolation
        bytes memory content1 = fs.readFile(SLOT_FILE1, 0, 0);
        bytes memory content2 = fs2.readFile(SLOT_FILE1, 0, 0);
        
        assertEq(string(content1), "Content in fs");
        assertEq(string(content2), "Content in fs2");
        vm.stopPrank();
    }
}
