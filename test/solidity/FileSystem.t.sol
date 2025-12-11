// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import "../../contracts/FileSystem.sol";
import "../../contracts/IFileSystem.sol";

contract FileSystemTest is Test {
    FileSystem public fs;
    address public user1;
    address public user2;

    function setUp() public {
        fs = new FileSystem();
        user1 = address(0x1);
        user2 = address(0x2);
    }

    function testCreateFile() public {
        vm.prank(user1);
        fs.createFile("test.txt", bytes("Hello, World!"));

        (
            string memory name,
            IFileSystem.EntryType entryType,
            address owner,
            bytes memory content,
            uint256 timestamp,
            bool entryExists
        ) = fs.getEntry(user1, "test.txt");

        assertTrue(entryExists);
        assertEq(name, "test.txt");
        assertEq(uint(entryType), uint(IFileSystem.EntryType.FILE));
        assertEq(owner, user1);
        assertEq(string(content), "Hello, World!");
        assertGt(timestamp, 0);
    }

    function testCreateDirectory() public {
        vm.prank(user1);
        fs.createDirectory("mydir");

        (
            string memory name,
            IFileSystem.EntryType entryType,
            address owner,
            bytes memory content,
            ,
            bool entryExists
        ) = fs.getEntry(user1, "mydir");

        assertTrue(entryExists);
        assertEq(name, "mydir");
        assertEq(uint(entryType), uint(IFileSystem.EntryType.DIRECTORY));
        assertEq(owner, user1);
        assertEq(content.length, 0);
    }

    function testUpdateFile() public {
        vm.startPrank(user1);
        fs.createFile("test.txt", bytes("Hello"));
        fs.updateFile("test.txt", bytes("World"));
        vm.stopPrank();

        (, , , bytes memory content, , ) = fs.getEntry(user1, "test.txt");
        assertEq(string(content), "World");
    }

    function testCannotCreateDuplicateFile() public {
        vm.startPrank(user1);
        fs.createFile("test.txt", bytes("Test"));
        
        vm.expectRevert("Entry already exists");
        fs.createFile("test.txt", bytes("Duplicate"));
        vm.stopPrank();
    }

    function testCannotCreateDuplicateDirectory() public {
        vm.startPrank(user1);
        fs.createDirectory("mydir");
        
        vm.expectRevert("Entry already exists");
        fs.createDirectory("mydir");
        vm.stopPrank();
    }

    function testDeleteFile() public {
        vm.startPrank(user1);
        fs.createFile("test.txt", bytes("Test"));
        fs.deleteEntry("test.txt");
        vm.stopPrank();

        (, , , , , bool entryExists) = fs.getEntry(user1, "test.txt");
        assertFalse(entryExists);
    }

    function testDeleteRemovesFromPathList() public {
        vm.startPrank(user1);
        fs.createFile("file1.txt", bytes("1"));
        fs.createFile("file2.txt", bytes("2"));
        fs.createFile("file3.txt", bytes("3"));
        
        string[] memory pathsBefore = fs.getAccountPaths(user1);
        assertEq(pathsBefore.length, 3);
        
        fs.deleteEntry("file2.txt");
        
        string[] memory pathsAfter = fs.getAccountPaths(user1);
        assertEq(pathsAfter.length, 2);
        
        // Verify file2.txt is not in the list
        bool found = false;
        for (uint i = 0; i < pathsAfter.length; i++) {
            if (keccak256(bytes(pathsAfter[i])) == keccak256(bytes("file2.txt"))) {
                found = true;
                break;
            }
        }
        assertFalse(found, "Deleted file should not be in paths list");
        vm.stopPrank();
    }

    function testCannotDeleteNonExistentEntry() public {
        vm.prank(user1);
        vm.expectRevert("Entry does not exist");
        fs.deleteEntry("nonexistent.txt");
    }

    function testOnlyOwnerCanUpdateFile() public {
        vm.prank(user1);
        fs.createFile("test.txt", bytes("Test"));

        vm.prank(user2);
        vm.expectRevert("Not owner");
        fs.updateFile("test.txt", bytes("Hacked"));
    }

    function testOnlyOwnerCanDeleteFile() public {
        vm.prank(user1);
        fs.createFile("test.txt", bytes("Test"));

        vm.prank(user2);
        vm.expectRevert("Not owner");
        fs.deleteEntry("test.txt");
    }

    function testCannotUpdateNonExistentFile() public {
        vm.prank(user1);
        vm.expectRevert("Entry does not exist");
        fs.updateFile("nonexistent.txt", bytes("Content"));
    }

    function testCannotUpdateDirectory() public {
        vm.startPrank(user1);
        fs.createDirectory("mydir");
        
        vm.expectRevert("Not a file");
        fs.updateFile("mydir", bytes("Content"));
        vm.stopPrank();
    }

    function testGetAccountPaths() public {
        vm.startPrank(user1);
        fs.createFile("file1.txt", bytes("1"));
        fs.createFile("file2.txt", bytes("2"));
        fs.createDirectory("dir1");
        vm.stopPrank();

        string[] memory paths = fs.getAccountPaths(user1);
        assertEq(paths.length, 3);
    }

    function testExistsFunction() public {
        vm.prank(user1);
        fs.createFile("test.txt", bytes("Test"));

        assertTrue(fs.exists(user1, "test.txt"));
        assertFalse(fs.exists(user1, "nonexistent.txt"));
        assertFalse(fs.exists(user2, "test.txt"));
    }

    function testMultipleAccountsIsolation() public {
        vm.prank(user1);
        fs.createFile("file.txt", bytes("User 1 content"));

        vm.prank(user2);
        fs.createFile("file.txt", bytes("User 2 content"));

        (, , , bytes memory content1, , ) = fs.getEntry(user1, "file.txt");
        (, , , bytes memory content2, , ) = fs.getEntry(user2, "file.txt");

        assertEq(string(content1), "User 1 content");
        assertEq(string(content2), "User 2 content");
    }

    function testFileTimestamp() public {
        uint256 beforeCreate = block.timestamp;
        
        vm.prank(user1);
        fs.createFile("test.txt", bytes("Test"));
        
        (, , , , uint256 timestamp, ) = fs.getEntry(user1, "test.txt");
        
        assertGe(timestamp, beforeCreate);
        assertLe(timestamp, block.timestamp);
    }

    function testUpdateTimestamp() public {
        vm.startPrank(user1);
        fs.createFile("test.txt", bytes("Test"));
        
        (, , , , uint256 timestamp1, ) = fs.getEntry(user1, "test.txt");
        
        vm.warp(block.timestamp + 100);
        fs.updateFile("test.txt", bytes("Updated"));
        
        (, , , , uint256 timestamp2, ) = fs.getEntry(user1, "test.txt");
        vm.stopPrank();
        
        assertGt(timestamp2, timestamp1);
    }
}
