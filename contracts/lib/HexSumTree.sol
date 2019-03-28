pragma solidity ^0.4.24;

import "./Checkpointing.sol"; // TODO: import from Staking (or somewhere else)


library HexSumTree {
    using Checkpointing for Checkpointing.History;

    struct Tree {
        uint256 nextKey;
        uint256 rootDepth;
        mapping (uint256 => mapping (uint256 => Checkpointing.History)) nodes; // depth -> key -> value
    }

    /* @dev
     * If you change any of the following 3 constants, make sure that:
     * 2^BITS_IN_NIBBLE = CHILDREN
     * BITS_IN_NIBBLE * MAX_DEPTH = 256
     */
    uint256 private constant CHILDREN = 16;
    uint256 private constant MAX_DEPTH = 64;
    uint256 private constant BITS_IN_NIBBLE = 4;
    uint256 private constant INSERTION_DEPTH = 0;
    uint256 private constant BASE_KEY = 0; // tree starts on the very left

    string private constant ERROR_SORTITION_OUT_OF_BOUNDS = "SUM_TREE_SORTITION_OUT_OF_BOUNDS";
    string private constant ERROR_NEW_KEY_NOT_ADJACENT = "SUM_TREE_NEW_KEY_NOT_ADJACENT";
    string private constant ERROR_UPDATE_OVERFLOW = "SUM_TREE_UPDATE_OVERFLOW";
    string private constant ERROR_INEXISTENT_ITEM = "SUM_TREE_INEXISTENT_ITEM";

    function init(Tree storage self) internal {
        self.rootDepth = INSERTION_DEPTH + 1;
        self.nextKey = BASE_KEY;
    }

    function insert(Tree storage self, uint256 value) internal returns (uint256) {
        uint256 key = self.nextKey;
        self.nextKey = nextKey(key);

        if (value > 0) {
            _set(self, key, value);
        }

        return key;
    }

    function set(Tree storage self, uint256 key, uint256 value) internal {
        require(key <= self.nextKey, ERROR_NEW_KEY_NOT_ADJACENT);
        _set(self, key, value);
    }

    function update(Tree storage self, uint256 key, uint256 delta, bool positive) internal {
        require(key < self.nextKey, ERROR_INEXISTENT_ITEM);

        uint256 oldValue = self.nodes[INSERTION_DEPTH][key].getLast();
        self.nodes[INSERTION_DEPTH][key].add(getBlockNumber64(), positive ? oldValue + delta : oldValue - delta);

        updateSums(self, key, delta, positive);
    }

    function sortition(Tree storage self, uint256 value, uint256 blockNumber) internal view returns (uint256 key, uint256 nodeValue) {
        require(totalSum(self) > value, ERROR_SORTITION_OUT_OF_BOUNDS);

        return _sortition(self, value, BASE_KEY, self.rootDepth, blockNumber);
    }

    function randomSortition(Tree storage self, uint256 seed, uint256 blockNumber) internal view returns (uint256 key, uint256 nodeValue) {
        return _sortition(self, seed % totalSum(self), BASE_KEY, self.rootDepth, blockNumber);
    }

    function _set(Tree storage self, uint256 key, uint256 value) private {
        uint256 oldValue = self.nodes[INSERTION_DEPTH][key].getLast();
        self.nodes[INSERTION_DEPTH][key].add(getBlockNumber64(), value);

        if (value > oldValue) {
            updateSums(self, key, value - oldValue, true);
        } else if (value < oldValue) {
            updateSums(self, key, oldValue - value, false);
        }
    }

    function _sortition(Tree storage self, uint256 value, uint256 node, uint256 depth, uint256 blockNumber) private view returns (uint256 key, uint256 nodeValue) {
        uint256 checkedValue = 0; // Can optimize by having checkedValue = value - remainingValue

        uint256 checkingLevel = depth - 1;
        // Invariant: node has 0's "after the depth" (so no need for masking)
        uint256 shift = checkingLevel * BITS_IN_NIBBLE;
        uint parentNode = node;
        uint256 child;
        uint256 checkingNode;
        uint256 nodeSum;
        for (; checkingLevel > INSERTION_DEPTH; checkingLevel--) {
            for (child = 0; child < CHILDREN; child++) {
                // shift the iterator and add it to node 0x00..0i00 (for depth = 3)
                checkingNode = parentNode + (child << shift);

                // TODO: 3 options
                // - leave it as is
                // -> use always get(blockNumber), as Checkpointing already short cuts it
                // - create another version of sortition for historic values, at the cost of repeating even more code
                if (blockNumber > 0) {
                    nodeSum = self.nodes[checkingLevel][checkingNode].get(blockNumber);
                } else {
                    nodeSum = self.nodes[checkingLevel][checkingNode].getLast();
                }
                if (checkedValue + nodeSum <= value) { // not reached yet, move to next child
                    checkedValue += nodeSum;
                } else { // value reached, move to next level
                    parentNode = checkingNode;
                    break;
                }
            }
            shift = shift - BITS_IN_NIBBLE;
        }
        // Leaves level:
        for (child = 0; child < CHILDREN; child++) {
            checkingNode = parentNode + child;
            // TODO: see above
            if (blockNumber > 0) {
                nodeSum = self.nodes[INSERTION_DEPTH][checkingNode].get(blockNumber);
            } else {
                nodeSum = self.nodes[INSERTION_DEPTH][checkingNode].getLast();
            }
            if (checkedValue + nodeSum <= value) { // not reached yet, move to next child
                checkedValue += nodeSum;
            } else { // value reached
                return (checkingNode, nodeSum);
            }
        }
        // Invariant: this point should never be reached
    }

    function updateSums(Tree storage self, uint256 key, uint256 delta, bool positive) private {
        uint256 newRootDepth = sharedPrefix(self.rootDepth, key);

        if (self.rootDepth != newRootDepth) {
            self.nodes[newRootDepth][BASE_KEY].add(getBlockNumber64(), self.nodes[self.rootDepth][BASE_KEY].getLast());
            self.rootDepth = newRootDepth;
        }

        uint256 mask = uint256(-1);
        uint256 ancestorKey = key;
        for (uint256 i = 1; i <= self.rootDepth; i++) {
            mask = mask << BITS_IN_NIBBLE;
            ancestorKey = ancestorKey & mask;

            // Invariant: this will never underflow.
            self.nodes[i][ancestorKey].add(getBlockNumber64(), positive ? self.nodes[i][ancestorKey].getLast() + delta : self.nodes[i][ancestorKey].getLast() - delta);
        }
        // it's only needed to check the last one, as the sum increases going up through the tree
        require(!positive || self.nodes[self.rootDepth][ancestorKey].getLast() >= delta, ERROR_UPDATE_OVERFLOW);
    }

    function totalSum(Tree storage self) internal view returns (uint256) {
        return self.nodes[self.rootDepth][BASE_KEY].getLast();
    }

    function get(Tree storage self, uint256 depth, uint256 key) internal view returns (uint256) {
        return self.nodes[depth][key].getLast();
    }

    function getItem(Tree storage self, uint256 key) internal view returns (uint256) {
        return self.nodes[INSERTION_DEPTH][key].getLast();
    }

    function getPastItem(Tree storage self, uint256 key, uint64 blockNumber) internal view returns (uint256) {
        return self.nodes[INSERTION_DEPTH][key].get(blockNumber);
    }

    function nextKey(uint256 fromKey) private pure returns (uint256) {
        return fromKey + 1;
    }

    function sharedPrefix(uint256 depth, uint256 key) internal pure returns (uint256) {
        uint256 shift = depth * BITS_IN_NIBBLE;
        uint256 mask = uint256(-1) << shift;
        uint keyAncestor = key & mask;

        if (keyAncestor != BASE_KEY) {
            return depth + 1;
        }

        return depth;
    }
    /*
    function sharedPrefix(uint256 depth, uint256 key) internal pure returns (uint256) {
        uint256 shift = depth * BITS_IN_NIBBLE;
        uint256 mask = uint256(-1) << shift;
        uint keyAncestor = key & mask;

        // in our use case this while should only have 1 iteration,
        // as new keys are always going to be "adjacent"
        while (keyAncestor != BASE_KEY) {
            mask = mask << BITS_IN_NIBBLE;
            keyAncestor &= mask;
            depth++;
        }
        return depth;
    }
    */

    // TODO: import?
    /*
    function toUint64(uint256 a) internal pure returns (uint64) {
        require(a <= MAX_UINT64, ERROR_NUMBER_TOO_BIG);
        return uint64(a);
    }
    */
    function getBlockNumber64() internal view returns (uint64) {
        return uint64(block.number);
    }
}
