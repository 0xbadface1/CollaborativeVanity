// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title LeadingZeros
/// @notice Counts leading zero BITS in a bytes32 value.
///         Used to measure "difficulty" of a hash — more leading zeros = harder to find.
///
/// HOW IT WORKS:
///   A bytes32 is 256 bits. We count how many of the most-significant bits are zero.
///   For example:
///     0x0000FFFF...  has 16 leading zero bits  (difficulty = 16)
///     0x00000000...  has 32+ leading zero bits (difficulty >= 32)
///     0xFFFFFFFF...  has 0 leading zero bits   (difficulty = 0)
///
///   We use a binary search approach: check the top 128 bits, then 64, then 32, etc.
///   This is O(log 256) = O(8) steps — very gas efficient.
library LeadingZeros {
    /// @notice Count the number of leading zero bits in a bytes32 value
    /// @param value The hash to count leading zeros in
    /// @return count The number of leading zero bits (0 to 256)
    function countLeadingZeroBits(bytes32 value) internal pure returns (uint256 count) {
        uint256 x = uint256(value);

        // If the entire value is zero, all 256 bits are zero
        if (x == 0) return 256;

        count = 0;

        // Binary search: check progressively smaller chunks from the top
        // Each step checks if the top N bits are all zero.
        // If so, shift left and add N to the count.

        if (x >> 128 == 0) { count += 128; x <<= 128; } // top 128 bits zero?
        if (x >> 192 == 0) { count +=  64; x <<=  64; } // top 64 of remaining?
        if (x >> 224 == 0) { count +=  32; x <<=  32; } // top 32 of remaining?
        if (x >> 240 == 0) { count +=  16; x <<=  16; } // top 16 of remaining?
        if (x >> 248 == 0) { count +=   8; x <<=   8; } // top 8 of remaining?
        if (x >> 252 == 0) { count +=   4; x <<=   4; } // top 4 of remaining?
        if (x >> 254 == 0) { count +=   2; x <<=   2; } // top 2 of remaining?
        if (x >> 255 == 0) { count +=   1;             } // top 1 of remaining?
    }
}
