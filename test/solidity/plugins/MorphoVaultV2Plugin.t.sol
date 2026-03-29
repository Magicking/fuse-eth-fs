// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "forge-std/Test.sol";
import "../../../contracts/plugins/morpho_vault_v2/MorphoVaultV2Plugin.sol";
import "../../../contracts/plugins/rpc_proxy/IRPCProxyPlugin.sol";
import "../../../contracts/IFileSystem.sol";

/**
 * @dev Minimal mock vault that returns name/symbol as real ERC20 would.
 */
contract MockVault {
    string private _name;
    string private _symbol;
    uint8  private _decimals;
    uint256 private _totalSupply;
    address private _asset;

    constructor(string memory name_, string memory symbol_) {
        _name        = name_;
        _symbol      = symbol_;
        _decimals    = 18;
        _totalSupply = 1_000e18;
        _asset       = address(0xA55e7);
    }

    function name()        external view returns (string memory) { return _name; }
    function symbol()      external view returns (string memory) { return _symbol; }
    function decimals()    external view returns (uint8)          { return _decimals; }
    function totalSupply() external view returns (uint256)        { return _totalSupply; }
    function asset()       external view returns (address)        { return _asset; }

    // Stub out remaining view functions so plugin calls don't revert
    function totalAssets()            external pure returns (uint256)  { return 0; }
    function virtualShares()          external pure returns (uint256)  { return 0; }
    function previewDeposit(uint256)  external pure returns (uint256)  { return 0; }
    function previewMint(uint256)     external pure returns (uint256)  { return 0; }
    function previewRedeem(uint256)   external pure returns (uint256)  { return 0; }
    function previewWithdraw(uint256) external pure returns (uint256)  { return 0; }
    function performanceFee()         external pure returns (uint96)   { return 0; }
    function performanceFeeRecipient() external pure returns (address) { return address(0); }
    function managementFee()          external pure returns (uint96)   { return 0; }
    function managementFeeRecipient() external pure returns (address)  { return address(0); }
    function _totalAssets()           external pure returns (uint256)  { return 0; }
    function lastUpdate()             external pure returns (uint64)   { return 0; }
    function maxRate()                external pure returns (uint64)   { return 0; }
    function accrueInterestView()     external pure returns (uint256, uint256, uint256) { return (0, 0, 0); }
    function owner()                  external pure returns (address)  { return address(0); }
    function curator()                external pure returns (address)  { return address(0); }
    function receiveSharesGate()      external pure returns (address)  { return address(0); }
    function sendSharesGate()         external pure returns (address)  { return address(0); }
    function receiveAssetsGate()      external pure returns (address)  { return address(0); }
    function sendAssetsGate()         external pure returns (address)  { return address(0); }
    function adapterRegistry()        external pure returns (address)  { return address(0); }
    function adaptersLength()         external pure returns (uint256)  { return 0; }
    function liquidityAdapter()       external pure returns (address)  { return address(0); }
    function liquidityData()          external pure returns (bytes memory) { return ""; }

    // Timelock & abdication tracking
    mapping(bytes4 => uint256) private _timelock;
    mapping(bytes4 => bool)    private _abdicated;

    function timelock(bytes4 selector)  external view returns (uint256) { return _timelock[selector]; }
    function abdicated(bytes4 selector) external view returns (bool)    { return _abdicated[selector]; }
    function setTimelock(bytes4 selector, uint256 value) external { _timelock[selector] = value; }
    function setAbdicated(bytes4 selector, bool value)   external { _abdicated[selector] = value; }
}

contract MorphoVaultV2PluginTest is Test {
    MockVault public vault;
    MorphoVaultV2Plugin public plugin;

    // Slot indices (must match _initMetrics / _initAbdicationMetrics order)
    uint256 constant SLOT_NAME   = 0;
    uint256 constant SLOT_SYMBOL = 1;

    // First abdication slot = number of regular metrics (29)
    uint256 constant ABDICATION_SLOT_OFFSET = 29;
    // Selector indices within _initAbdicationMetrics
    uint256 constant ABDICATION_SLOT_SET_IS_ALLOCATOR    = ABDICATION_SLOT_OFFSET + 0;
    uint256 constant ABDICATION_SLOT_ADD_ADAPTER         = ABDICATION_SLOT_OFFSET + 6;
    uint256 constant ABDICATION_SLOT_SET_PERFORMANCE_FEE = ABDICATION_SLOT_OFFSET + 11;

    function setUp() public {
        vault  = new MockVault("My Morpho Vault", "MMV");
        plugin = new MorphoVaultV2Plugin(address(vault));
    }

    // ── helpers ──────────────────────────────────────────────────────────────

    /// Execute the full two-phase RPC proxy flow for a given slot and return
    /// the formatted file content as a string.
    function _readSlot(uint256 slot) internal returns (string memory) {
        // Phase 1: get descriptor
        IRPCProxyPlugin.RPCDescriptor memory desc = plugin.getRPCDescriptor(slot);

        // Phase 2: execute the call(s) against the mock vault
        bytes memory rawResult;
        if (desc.callType == IRPCProxyPlugin.RPCCallType.BATCH_CALL) {
            (address[] memory targets, bytes[] memory calldatas) =
                abi.decode(desc.callData, (address[], bytes[]));
            bytes[] memory results = new bytes[](targets.length);
            for (uint256 i = 0; i < targets.length; i++) {
                (bool ok, bytes memory r) = targets[i].call(calldatas[i]);
                assertTrue(ok, "batch sub-call failed");
                results[i] = r;
            }
            rawResult = abi.encode(results);
        } else {
            (bool ok, bytes memory r) = desc.targetAddress.call(desc.callData);
            assertTrue(ok, "vault call failed");
            rawResult = r;
        }

        // Phase 3: format
        bytes memory content = plugin.formatRPCResult(slot, rawResult);
        return string(content);
    }

    // ── isRPCProxy ────────────────────────────────────────────────────────────

    function test_isRPCProxy() public view {
        assertTrue(plugin.isRPCProxy());
    }

    // ── name / symbol (STRING_RESULT) ────────────────────────────────────────

    function test_name_notEmpty() public {
        string memory content = _readSlot(SLOT_NAME);
        assertGt(bytes(content).length, 0, "name content is empty");
    }

    function test_name_containsVaultName() public {
        string memory content = _readSlot(SLOT_NAME);
        assertTrue(
            _contains(content, "My Morpho Vault"),
            "formatted name does not contain vault name"
        );
    }

    function test_symbol_notEmpty() public {
        string memory content = _readSlot(SLOT_SYMBOL);
        assertGt(bytes(content).length, 0, "symbol content is empty");
    }

    function test_symbol_containsVaultSymbol() public {
        string memory content = _readSlot(SLOT_SYMBOL);
        assertTrue(
            _contains(content, "MMV"),
            "formatted symbol does not contain vault symbol"
        );
    }

    /// Regression: _decodeString used to read data[32+offset+32+i] instead of
    /// data[offset+32+i], causing an out-of-bounds revert for any non-empty string.
    function test_decodeString_doesNotRevert_shortName() public {
        MockVault v2 = new MockVault("A", "B");
        MorphoVaultV2Plugin p2 = new MorphoVaultV2Plugin(address(v2));

        IRPCProxyPlugin.RPCDescriptor memory desc = p2.getRPCDescriptor(SLOT_NAME);
        (, bytes memory raw) = desc.targetAddress.call(desc.callData);
        bytes memory content = p2.formatRPCResult(SLOT_NAME, raw); // must not revert
        assertGt(content.length, 0);
    }

    function test_decodeString_doesNotRevert_longName() public {
        MockVault v2 = new MockVault("A Very Long Vault Name That Exceeds 32 Bytes For Sure", "LONG");
        MorphoVaultV2Plugin p2 = new MorphoVaultV2Plugin(address(v2));

        IRPCProxyPlugin.RPCDescriptor memory desc = p2.getRPCDescriptor(SLOT_NAME);
        (, bytes memory raw) = desc.targetAddress.call(desc.callData);
        bytes memory content = p2.formatRPCResult(SLOT_NAME, raw);
        assertTrue(_contains(string(content), "A Very Long Vault Name"));
    }

    // ── timelock params (BATCH_CALL) ──────────────────────────────────────────

    function test_timelockParams_noDelay_notAbdicated() public {
        string memory content = _readSlot(ABDICATION_SLOT_SET_IS_ALLOCATOR);
        assertTrue(_contains(content, "0s (no delay)"), "expected no-delay label");
        assertTrue(_contains(content, "abdicated: false"), "expected not abdicated");
    }

    function test_timelockParams_withDelay() public {
        bytes4 sel = bytes4(keccak256("setIsAllocator(address,bool)"));
        vault.setTimelock(sel, 86400);
        string memory content = _readSlot(ABDICATION_SLOT_SET_IS_ALLOCATOR);
        assertTrue(_contains(content, "86400"), "expected duration in seconds");
        assertTrue(_contains(content, "1d"), "expected days label");
    }

    function test_timelockParams_abdicated_showsTrue() public {
        bytes4 sel = bytes4(keccak256("setIsAllocator(address,bool)"));
        vault.setAbdicated(sel, true);
        string memory content = _readSlot(ABDICATION_SLOT_SET_IS_ALLOCATOR);
        assertTrue(_contains(content, "abdicated: true"), "expected abdicated flag");
    }

    function test_timelockParams_containsSelectorName() public {
        string memory content = _readSlot(ABDICATION_SLOT_ADD_ADAPTER);
        assertTrue(_contains(content, "timelocks/addAdapter"), "content missing selector name");
    }

    function test_timelockParams_allSlotsReturnContent() public {
        for (uint256 i = 0; i < 18; i++) {
            string memory content = _readSlot(ABDICATION_SLOT_OFFSET + i);
            assertGt(bytes(content).length, 0, "timelock slot returned empty content");
            assertTrue(_contains(content, "timelock:"), "missing timelock field");
            assertTrue(_contains(content, "abdicated:"), "missing abdicated field");
        }
    }

    function test_timelocksDirExists() public view {
        uint256 total = plugin.totalEntries();
        // timelocks directory is the last directory entry
        uint256 timelocksDirSlot = total - 1;
        (
            IFileSystem.EntryType entryType,
            ,
            bytes memory name,
            ,,,,
        ) = plugin.getEntry(timelocksDirSlot);
        assertEq(uint8(entryType), uint8(IFileSystem.EntryType.DIRECTORY));
        assertEq(string(name), "timelocks");
    }

    // ── string search helper ──────────────────────────────────────────────────

    function _contains(string memory haystack, string memory needle) internal pure returns (bool) {
        bytes memory h = bytes(haystack);
        bytes memory n = bytes(needle);
        if (n.length > h.length) return false;
        for (uint256 i = 0; i <= h.length - n.length; i++) {
            bool found = true;
            for (uint256 j = 0; j < n.length; j++) {
                if (h[i + j] != n[j]) { found = false; break; }
            }
            if (found) return true;
        }
        return false;
    }
}
