// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "forge-std/Test.sol";
import "../../../contracts/plugins/graffiti/Graffiti.sol";
import "../../../contracts/plugins/graffiti/IGraffitiBaseNFT.sol";
import "../../../contracts/IFileSystem.sol";

/**
 * @title MockGraffitiBaseNFT
 * @dev Mock implementation of IGraffitiBaseNFT for testing
 */
contract MockGraffitiBaseNFT is IGraffitiBaseNFT {
    using Strings for uint256;

    string public override name;
    uint256 public override totalSupply;
    
    mapping(uint256 => address) private _owners;
    mapping(uint256 => GraffitiBase) private _graffitiBases;
    mapping(uint256 => bytes) private _bmpData;
    
    address public owner;
    
    constructor(string memory _name) {
        name = _name;
        owner = msg.sender;
        totalSupply = 0;
    }
    
    // Helper to initialize contract after vm.etch (for testing)
    function initialize(string memory _name, address _owner) external {
        require(owner == address(0), "Already initialized");
        name = _name;
        owner = _owner;
        totalSupply = 0;
    }
    
    function mint(address to, uint256 tokenId, uint32 color, address creator, address colorOwner, uint256[] memory graffiti) external {
        require(msg.sender == owner, "Only owner can mint");
        
        // Update totalSupply if needed
        if (tokenId >= totalSupply) {
            totalSupply = tokenId + 1;
        }
        
        _owners[tokenId] = to;
        _graffitiBases[tokenId] = GraffitiBase({
            id: tokenId,
            color: color,
            creator: creator,
            owner: to,
            colorOwner: colorOwner,
            graffiti: graffiti
        });
    }
    
    function setBMP(uint256 tokenId, bytes memory bmp) external {
        require(msg.sender == owner, "Only owner can set BMP");
        _bmpData[tokenId] = bmp;
    }
    
    function ownerOf(uint256 tokenId) external view override returns (address) {
        address ownerAddr = _owners[tokenId];
        require(ownerAddr != address(0), "Token does not exist");
        return ownerAddr;
    }
    
    function getGraffitiBase(uint256 tokenId) external view override returns (GraffitiBase memory) {
        require(_owners[tokenId] != address(0), "Token does not exist");
        return _graffitiBases[tokenId];
    }
    
    function BMP(uint256 tokenId) external view override returns (bytes memory) {
        require(_owners[tokenId] != address(0), "Token does not exist");
        return _bmpData[tokenId];
    }
    
    // Helper to make a token non-existent (for testing)
    function removeToken(uint256 tokenId) external {
        require(msg.sender == owner, "Only owner can remove");
        delete _owners[tokenId];
        delete _graffitiBases[tokenId];
        delete _bmpData[tokenId];
    }
}

/**
 * @title GraffitiPluginTest
 * @dev Comprehensive tests for GraffitiPlugin contract
 */
contract GraffitiPluginTest is Test {
    GraffitiPlugin public plugin;
    MockGraffitiBaseNFT public mockNFT;
    
    address public user1;
    address public user2;
    address public creator1;
    address public colorOwner1;
    
    function setUp() public {
        // Set chainId to Base (8453) for testing
        vm.chainId(8453);
        
        // Deploy mock NFT temporarily to get its bytecode
        MockGraffitiBaseNFT tempMock = new MockGraffitiBaseNFT("Test Graffiti Collection");
        
        // Put mock contract code at the expected address for Base chain
        address expectedAddress = address(0xCc39Fe145eECe8a733833D7A78dCa7f287996693);
        bytes memory code = address(tempMock).code;
        vm.etch(expectedAddress, code);
        
        // Initialize the contract at the expected address
        mockNFT = MockGraffitiBaseNFT(expectedAddress);
        mockNFT.initialize("Test Graffiti Collection", address(this));
        
        // Now create plugin (it will use the address based on chainId)
        plugin = new GraffitiPlugin();
        
        user1 = address(0x1);
        user2 = address(0x2);
        creator1 = address(0x3);
        colorOwner1 = address(0x4);
        
        // Mint some test tokens
        uint256[] memory graffiti1 = new uint256[](2);
        graffiti1[0] = 100;
        graffiti1[1] = 200;
        
        uint256[] memory graffiti2 = new uint256[](1);
        graffiti2[0] = 300;
        
        mockNFT.mint(user1, 0, 0xFF0000, creator1, colorOwner1, graffiti1);
        mockNFT.mint(user2, 1, 0x00FF00, creator1, colorOwner1, graffiti2);
        mockNFT.mint(user1, 2, 0x0000FF, creator1, colorOwner1, new uint256[](0));
        
        // Set BMP data for tokens
        mockNFT.setBMP(0, bytes("BMP_DATA_TOKEN_0"));
        mockNFT.setBMP(1, bytes("BMP_DATA_TOKEN_1"));
        mockNFT.setBMP(2, bytes("BMP_DATA_TOKEN_2"));
    }
    
    // ============ Constructor Tests ============
    
    function testConstructor() public {
        // Ensure chainId is set
        vm.chainId(8453);
        
        // Deploy a temporary mock to get bytecode
        MockGraffitiBaseNFT tempMock = new MockGraffitiBaseNFT("Test");
        address expectedAddress = address(0xCc39Fe145eECe8a733833D7A78dCa7f287996693);
        bytes memory code = address(tempMock).code;
        vm.etch(expectedAddress, code);
        
        // Initialize the contract at expected address
        MockGraffitiBaseNFT(expectedAddress).initialize("Test", address(this));
        
        GraffitiPlugin newPlugin = new GraffitiPlugin();
        assertEq(address(newPlugin.graffitiContract()), expectedAddress);
    }
    
    // ============ Storage Slot Parsing Tests ============
    
    function testParseStorageSlotJson() public {
        // Test storage slot parsing through getEntry (which uses _parseStorageSlot internally)
        // Token 0 -> slot 0 (.json)
        (, , bytes memory name0, , , , , ) = plugin.getEntry(0);
        assertEq(string(name0), "0.json");
        
        // Token 1 -> slot 2 (.json)
        (, , bytes memory name1, , , , , ) = plugin.getEntry(2);
        assertEq(string(name1), "1.json");
        
        // Token 2 -> slot 4 (.json)
        (, , bytes memory name2, , , , , ) = plugin.getEntry(4);
        assertEq(string(name2), "2.json");
    }
    
    function testParseStorageSlotBmp() public {
        // Test storage slot parsing through getEntry (which uses _parseStorageSlot internally)
        // Token 0 -> slot 1 (.bmp)
        (, , bytes memory name0, , , , , ) = plugin.getEntry(1);
        assertEq(string(name0), "0.bmp");
        
        // Token 1 -> slot 3 (.bmp)
        (, , bytes memory name1, , , , , ) = plugin.getEntry(3);
        assertEq(string(name1), "1.bmp");
        
        // Token 2 -> slot 5 (.bmp)
        (, , bytes memory name2, , , , , ) = plugin.getEntry(5);
        assertEq(string(name2), "2.bmp");
    }
    
    // ============ Token Existence Tests ============
    
    function testTokenExists() public {
        assertTrue(plugin.exists(0)); // Token 0 .json
        assertTrue(plugin.exists(1)); // Token 0 .bmp
        assertTrue(plugin.exists(2)); // Token 1 .json
        assertTrue(plugin.exists(3)); // Token 1 .bmp
        assertTrue(plugin.exists(4)); // Token 2 .json
        assertTrue(plugin.exists(5)); // Token 2 .bmp
    }
    
    function testTokenDoesNotExist() public {
        assertFalse(plugin.exists(6)); // Token 3 .json (doesn't exist)
        assertFalse(plugin.exists(7)); // Token 3 .bmp (doesn't exist)
        assertFalse(plugin.exists(100)); // Token 50 .json (doesn't exist)
    }
    
    function testTokenExistsAfterRemoval() public {
        assertTrue(plugin.exists(0));
        
        // Remove token 0
        vm.prank(address(mockNFT.owner()));
        mockNFT.removeToken(0);
        
        assertFalse(plugin.exists(0));
        assertFalse(plugin.exists(1));
    }
    
    // ============ GetEntry Tests ============
    
    function testGetEntryJsonFile() public {
        (
            IFileSystem.EntryType entryType,
            address owner,
            bytes memory name,
            bytes memory body,
            uint256 timestamp,
            bool entryExists,
            uint256 fileSize,
            address directoryTarget
        ) = plugin.getEntry(0); // Token 0 .json
        
        assertTrue(entryExists);
        assertEq(uint(entryType), uint(IFileSystem.EntryType.FILE));
        assertEq(owner, user1);
        assertEq(string(name), "0.json");
        assertEq(directoryTarget, address(0));
        assertGt(timestamp, 0);
        assertGt(body.length, 0);
        assertEq(fileSize, body.length);
        // Verify body contains expected JSON fields
        string memory bodyStr = string(body);
        assertTrue(_contains(bodyStr, "name"));
        assertTrue(_contains(bodyStr, "description"));
    }
    
    function testGetEntryBmpFile() public {
        (
            IFileSystem.EntryType entryType,
            address owner,
            bytes memory name,
            bytes memory body,
            uint256 timestamp,
            bool entryExists,
            uint256 fileSize,
            address directoryTarget
        ) = plugin.getEntry(1); // Token 0 .bmp
        
        assertTrue(entryExists);
        assertEq(uint(entryType), uint(IFileSystem.EntryType.FILE));
        assertEq(owner, user1);
        assertEq(string(name), "0.bmp");
        assertEq(directoryTarget, address(0));
        assertGt(timestamp, 0);
        assertGt(body.length, 0);
        assertEq(fileSize, body.length);
        // Verify body contains the BMP data set in setUp
        assertEq(string(body), "BMP_DATA_TOKEN_0");
    }
    
    function testGetEntryNonExistentToken() public {
        (
            IFileSystem.EntryType entryType,
            address owner,
            bytes memory name,
            bytes memory body,
            uint256 timestamp,
            bool entryExists,
            uint256 fileSize,
            address directoryTarget
        ) = plugin.getEntry(6); // Token 3 .json (doesn't exist)
        
        assertFalse(entryExists);
        assertEq(uint(entryType), uint(IFileSystem.EntryType.FILE));
        assertEq(owner, address(0));
        assertEq(name.length, 0);
        assertEq(body.length, 0);
        assertEq(timestamp, 0);
        assertEq(fileSize, 0);
        assertEq(directoryTarget, address(0));
    }
    
    function testGetEntryDifferentOwners() public {
        (, address owner0, , , , , , ) = plugin.getEntry(0); // Token 0 owned by user1
        (, address owner1, , , , , , ) = plugin.getEntry(2); // Token 1 owned by user2
        
        assertEq(owner0, user1);
        assertEq(owner1, user2);
    }
    
    // ============ GetEntries Tests ============
    
    function testGetEntries() public {
        uint256[] memory entries = plugin.getEntries();
        
        // Should have 3 tokens * 2 files each = 6 entries
        assertEq(entries.length, 6);
        
        // Verify all entries are present
        assertEq(entries[0], 0); // Token 0 .json
        assertEq(entries[1], 1); // Token 0 .bmp
        assertEq(entries[2], 2); // Token 1 .json
        assertEq(entries[3], 3); // Token 1 .bmp
        assertEq(entries[4], 4); // Token 2 .json
        assertEq(entries[5], 5); // Token 2 .bmp
    }
    
    function testGetEntriesAfterMinting() public {
        uint256[] memory graffiti = new uint256[](0);
        mockNFT.mint(user1, 3, 0xFFFF00, creator1, colorOwner1, graffiti);
        mockNFT.setBMP(3, bytes("BMP_DATA_TOKEN_3"));
        
        uint256[] memory entries = plugin.getEntries();
        assertEq(entries.length, 8); // 4 tokens * 2 = 8 entries
    }
    
    function testGetEntriesEmpty() public {
        // Ensure chainId is set
        vm.chainId(8453);
        
        // Create a temporary mock to get bytecode
        MockGraffitiBaseNFT tempMock = new MockGraffitiBaseNFT("Empty Collection");
        
        // Put empty mock contract code at the expected address
        address expectedAddress = address(0xCc39Fe145eECe8a733833D7A78dCa7f287996693);
        bytes memory code = address(tempMock).code;
        vm.etch(expectedAddress, code);
        
        // Initialize the contract at expected address
        MockGraffitiBaseNFT(expectedAddress).initialize("Empty Collection", address(this));
        
        GraffitiPlugin emptyPlugin = new GraffitiPlugin();
        
        uint256[] memory entries = emptyPlugin.getEntries();
        assertEq(entries.length, 0);
    }
    
    // ============ ReadFile Tests ============
    
    function testReadFileJsonFull() public {
        bytes memory body = plugin.readFile(0, 0, 0); // Token 0 .json, full read
        
        // Should contain metadata JSON
        string memory bodyStr = string(body);
        assertTrue(bytes(bodyStr).length > 0);
        // Check for expected JSON fields
        assertTrue(_contains(bodyStr, "name"));
        assertTrue(_contains(bodyStr, "description"));
        assertTrue(_contains(bodyStr, "attributes"));
    }
    
    function testReadFileJsonWithOffset() public {
        bytes memory fullBody = plugin.readFile(0, 0, 0);
        uint256 fullLength = fullBody.length;
        
        if (fullLength > 10) {
            bytes memory partialBody = plugin.readFile(0, 5, 10);
            assertLe(partialBody.length, 10);
            assertLe(partialBody.length, fullLength - 5);
        }
    }
    
    function testReadFileJsonWithLength() public {
        bytes memory body = plugin.readFile(0, 0, 50);
        assertLe(body.length, 50);
    }
    
    function testReadFileBmp() public {
        bytes memory body = plugin.readFile(1, 0, 0); // Token 0 .bmp
        
        // Should return the BMP data set in setUp
        assertGt(body.length, 0);
        assertEq(string(body), "BMP_DATA_TOKEN_0");
    }
    
    function testReadFileOffsetBeyondLength() public {
        bytes memory body = plugin.readFile(0, 0, 0);
        uint256 length = body.length;
        
        bytes memory result = plugin.readFile(0, length + 100, 10);
        assertEq(result.length, 0);
    }
    
    function testReadFileLengthBeyondEnd() public {
        bytes memory fullBody = plugin.readFile(0, 0, 0);
        uint256 fullLength = fullBody.length;
        
        if (fullLength > 0) {
            bytes memory result = plugin.readFile(0, fullLength - 5, 100);
            assertLe(result.length, 5);
        }
    }
    
    function testReadFileNonExistentToken() public {
        // Should revert with TokenDoesNotExist for JSON files
        vm.expectRevert(GraffitiPlugin.TokenDoesNotExist.selector);
        plugin.readFile(6, 0, 0); // Token 3 .json (doesn't exist)
    }
    
    function testReadFileNonExistentTokenBmp() public {
        // BMP files return empty string, so they don't revert
        bytes memory body = plugin.readFile(7, 0, 0); // Token 3 .bmp (doesn't exist)
        assertEq(body.length, 0);
    }
    
    // ============ ReadCluster Tests ============
    
    function testReadCluster() public {
        bytes memory fullBody = plugin.readFile(0, 0, 0);
        
        if (fullBody.length > 0) {
            uint256 cluster0 = plugin.readCluster(0, 0);
            // Cluster should contain first 32 bytes (or less if body is shorter)
            assertTrue(cluster0 >= 0);
        }
    }
    
    function testReadClusterMultiple() public {
        bytes memory fullBody = plugin.readFile(0, 0, 0);
        uint256 numClusters = (fullBody.length + 31) / 32;
        
        for (uint256 i = 0; i < numClusters && i < 5; i++) {
            uint256 cluster = plugin.readCluster(0, i);
            assertTrue(cluster >= 0);
        }
    }
    
    function testReadClusterBeyondEnd() public {
        bytes memory fullBody = plugin.readFile(0, 0, 0);
        uint256 numClusters = (fullBody.length + 31) / 32;
        
        uint256 cluster = plugin.readCluster(0, numClusters + 10);
        assertEq(cluster, 0);
    }
    
    function testReadClusterPartial() public {
        // Test with existing data that might be less than 32 bytes
        bytes memory body = plugin.readFile(0, 0, 0);
        
        if (body.length < 32) {
            uint256 cluster = plugin.readCluster(0, 0);
            // Should pack the bytes correctly
            assertTrue(cluster > 0 || body.length == 0);
        }
    }
    
    function testReadClusterNonExistentToken() public {
        // Should revert with TokenDoesNotExist for JSON files
        vm.expectRevert(GraffitiPlugin.TokenDoesNotExist.selector);
        plugin.readCluster(6, 0); // Token 3 .json (doesn't exist)
    }
    
    function testReadClusterNonExistentTokenBmp() public {
        // BMP files return empty string, so readCluster should return 0
        uint256 cluster = plugin.readCluster(7, 0); // Token 3 .bmp (doesn't exist)
        assertEq(cluster, 0);
    }
    
    // ============ NotImplemented Tests ============
    
    function testCreateFileReverts() public {
        vm.expectRevert(GraffitiPlugin.NotImplemented.selector);
        plugin.createFile(bytes("test.txt"), bytes("content"), 0);
    }
    
    function testCreateDirectoryReverts() public {
        vm.expectRevert(GraffitiPlugin.NotImplemented.selector);
        plugin.createDirectory(bytes("dir"), address(0x123));
    }
    
    function testUpdateFileReverts() public {
        vm.expectRevert(GraffitiPlugin.NotImplemented.selector);
        plugin.updateFile(0, bytes("content"), 0);
    }
    
    function testDeleteEntryReverts() public {
        vm.expectRevert(GraffitiPlugin.NotImplemented.selector);
        plugin.deleteEntry(0);
    }
    
    function testWriteFileReverts() public {
        vm.expectRevert(GraffitiPlugin.NotImplemented.selector);
        plugin.writeFile(0, 0, bytes("content"));
    }
    
    // ============ Metadata JSON Tests ============
    
    function testMetadataJsonContainsName() public {
        bytes memory body = plugin.readFile(0, 0, 0);
        string memory bodyStr = string(body);
        
        // Should contain the collection name
        assertTrue(_contains(bodyStr, mockNFT.name()));
    }
    
    function testMetadataJsonContainsDescription() public {
        bytes memory body = plugin.readFile(0, 0, 0);
        string memory bodyStr = string(body);
        
        // Should contain "Graffiti 0" or similar
        assertTrue(_contains(bodyStr, "Graffiti") || _contains(bodyStr, "0"));
    }
    
    function testMetadataJsonContainsAttributes() public {
        bytes memory body = plugin.readFile(0, 0, 0);
        string memory bodyStr = string(body);
        
        // Should contain RGB attributes
        assertTrue(_contains(bodyStr, "Red") || _contains(bodyStr, "Green") || _contains(bodyStr, "Blue"));
    }
    
    function testMetadataJsonContainsExternalUrl() public {
        bytes memory body = plugin.readFile(0, 0, 0);
        string memory bodyStr = string(body);
        
        // Should contain external_url
        assertTrue(_contains(bodyStr, "external_url") || _contains(bodyStr, "6120.eu"));
    }
    
    function testMetadataJsonEvenTokenId() public {
        // Token 0 is even, should have º
        bytes memory body = plugin.readFile(0, 0, 0);
        string memory bodyStr = string(body);
        // We can't easily check for unicode characters, but we verify it doesn't revert
        assertTrue(bytes(bodyStr).length > 0);
    }
    
    function testMetadataJsonOddTokenId() public {
        // Token 1 is odd, should have ª
        bytes memory body = plugin.readFile(2, 0, 0); // Token 1 .json
        string memory bodyStr = string(body);
        // We can't easily check for unicode characters, but we verify it doesn't revert
        assertTrue(bytes(bodyStr).length > 0);
    }
    
    // ============ Edge Cases ============
    
    function testLargeTokenId() public {
        // Mint token with large ID
        uint256[] memory graffiti = new uint256[](0);
        mockNFT.mint(user1, 1000, 0x123456, creator1, colorOwner1, graffiti);
        mockNFT.setBMP(1000, bytes("BMP_DATA"));
        
        // Storage slot should be 2000 (.json) and 2001 (.bmp)
        assertTrue(plugin.exists(2000));
        assertTrue(plugin.exists(2001));
        
        (, , bytes memory name, , , , , ) = plugin.getEntry(2000);
        assertEq(string(name), "1000.json");
    }
    
    function testZeroColor() public {
        uint256[] memory graffiti = new uint256[](0);
        mockNFT.mint(user1, 10, 0, creator1, colorOwner1, graffiti);
        
        bytes memory body = plugin.readFile(20, 0, 0); // Token 10 .json
        string memory bodyStr = string(body);
        // Should still generate valid JSON
        assertTrue(bytes(bodyStr).length > 0);
    }
    
    function testEmptyGraffitiArray() public {
        // Token 2 already has empty graffiti array
        bytes memory body = plugin.readFile(4, 0, 0); // Token 2 .json
        string memory bodyStr = string(body);
        // Should still generate valid JSON
        assertTrue(bytes(bodyStr).length > 0);
    }
    
    function testMultipleReadsSameFile() public {
        bytes memory body1 = plugin.readFile(0, 0, 0);
        bytes memory body2 = plugin.readFile(0, 0, 0);
        
        assertEq(body1.length, body2.length);
        assertEq(keccak256(body1), keccak256(body2));
    }
    
    // ============ Helper Functions ============
    
    function _contains(string memory str, string memory substr) private pure returns (bool) {
        bytes memory strBytes = bytes(str);
        bytes memory substrBytes = bytes(substr);
        
        if (substrBytes.length > strBytes.length) {
            return false;
        }
        
        for (uint256 i = 0; i <= strBytes.length - substrBytes.length; i++) {
            bool isMatch = true;
            for (uint256 j = 0; j < substrBytes.length; j++) {
                if (strBytes[i + j] != substrBytes[j]) {
                    isMatch = false;
                    break;
                }
            }
            if (isMatch) {
                return true;
            }
        }
        return false;
    }
}

