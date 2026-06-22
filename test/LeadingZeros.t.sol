// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {LeadingZeros} from "../src/libraries/LeadingZeros.sol";

/// @title LeadingZerosTest
/// @notice Tests for the LeadingZeros library — the core difficulty measurement.
///
/// WHAT WE'RE TESTING:
///   The library counts leading zero BITS in a bytes32 value.
///   This is used to measure "difficulty" of a hash:
///     0x0000...  → many leading zeros → high difficulty → rare
///     0xFFFF...  → no leading zeros → zero difficulty → common
///
/// WHY THIS MATTERS:
///   If this function is wrong, shares get incorrect difficulty scores.
///   Since all credits and distributions flow from difficulty measurement,
///   this is the most critical function to get right.
contract LeadingZerosTest is Test {
    using LeadingZeros for bytes32;

    // =========================================================================
    //                         EXACT VALUES
    // =========================================================================

    function test_allZeros() public pure {
        assertEq(bytes32(0).countLeadingZeroBits(), 256);
    }

    function test_allOnes() public pure {
        assertEq(bytes32(type(uint256).max).countLeadingZeroBits(), 0);
    }

    function test_singleHighBit() public pure {
        // 0x8000...0000 — highest bit set, rest zero → 0 leading zeros
        bytes32 val = bytes32(uint256(1) << 255);
        assertEq(val.countLeadingZeroBits(), 0);
    }

    function test_singleLowBit() public pure {
        // 0x0000...0001 — only lowest bit set → 255 leading zeros
        bytes32 val = bytes32(uint256(1));
        assertEq(val.countLeadingZeroBits(), 255);
    }

    function test_exactly16LeadingZeros() public pure {
        // 0x0000FFFF...FFFF — 16 zero bits then all ones
        // = top 2 bytes are 0, third byte is 0xFF
        bytes32 val = bytes32(uint256(type(uint256).max) >> 16);
        assertEq(val.countLeadingZeroBits(), 16);
    }

    function test_exactly32LeadingZeros() public pure {
        bytes32 val = bytes32(uint256(type(uint256).max) >> 32);
        assertEq(val.countLeadingZeroBits(), 32);
    }

    function test_exactly64LeadingZeros() public pure {
        bytes32 val = bytes32(uint256(type(uint256).max) >> 64);
        assertEq(val.countLeadingZeroBits(), 64);
    }

    function test_exactly128LeadingZeros() public pure {
        bytes32 val = bytes32(uint256(type(uint256).max) >> 128);
        assertEq(val.countLeadingZeroBits(), 128);
    }

    // =========================================================================
    //                      BOUNDARY VALUES
    // =========================================================================

    function test_oneBitAtEachPosition() public pure {
        // Setting bit N (from MSB) should give N leading zeros
        for (uint256 i = 0; i < 256; i++) {
            bytes32 val = bytes32(uint256(1) << (255 - i));
            assertEq(
                val.countLeadingZeroBits(),
                i,
                string.concat("Bit at position ", vm.toString(i))
            );
        }
    }

    // =========================================================================
    //                         FUZZ TEST
    // =========================================================================

    /// @notice Fuzz test: verify against a naive bit-counting implementation.
    ///         Foundry generates random bytes32 values and checks both methods agree.
    function testFuzz_matchesNaiveCount(bytes32 value) public pure {
        uint256 fast = value.countLeadingZeroBits();
        uint256 naive = _naiveLeadingZeros(value);
        assertEq(fast, naive, "Fast and naive implementations must agree");
    }

    /// @notice Naive O(256) implementation — check each bit from the top.
    ///         Slow but obviously correct. Used as reference for the optimized version.
    function _naiveLeadingZeros(bytes32 value) internal pure returns (uint256 count) {
        uint256 x = uint256(value);
        if (x == 0) return 256;
        count = 0;
        for (uint256 bit = 255; ; bit--) {
            if ((x >> bit) & 1 == 1) return count;
            count++;
            if (bit == 0) break;
        }
    }

    // =========================================================================
    //                     REAL-WORLD HASH VALUES
    // =========================================================================

    function test_keccakHashDifficulty() public pure {
        // Hash of "hello" — a real keccak256 output
        bytes32 h = keccak256("hello");
        // keccak256("hello") = 0x1c8aff950685c2ed4bc3174f3472287b56d9517b9c948127319a09a7a36deac8
        // First nibble is 0x1 = 0001 in binary → 3 leading zero bits
        assertEq(h.countLeadingZeroBits(), 3);
    }
}
