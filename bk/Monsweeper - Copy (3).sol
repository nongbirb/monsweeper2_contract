// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/access/Ownable.sol";

contract Monsweeper is Ownable {
    struct Game {
        address player;
        uint256 seed;
        uint256 bet;
        bool active;
        uint8[] clickedTiles; // Store sequence of clicked tiles
    }

    mapping(bytes32 => Game) public games;
    uint8 constant BOARD_SIZE = 36;
    uint8 constant NUM_BOMBS = 9;

    event GameStarted(bytes32 gameId, address player, uint256 bet);
    event CashedOut(bytes32 gameId, uint256 reward);
    event GameOver(bytes32 gameId);
    event OwnerWithdrawn(address indexed owner, uint256 amount);

    // Constructor to set the contract deployer as the owner
    constructor() Ownable(msg.sender) {}

    function startGame(uint256 seed) external payable returns (bytes32) {
        require(msg.value > 0, "Bet must be greater than 0");
        
        bytes32 gameId = keccak256(abi.encode(msg.sender, seed, block.timestamp));
        Game storage game = games[gameId];
        require(!game.active, "Game already active");

        game.player = msg.sender;
        game.seed = seed;
        game.bet = msg.value;
        game.active = true;
        delete game.clickedTiles; // Clear any previous data

        emit GameStarted(gameId, msg.sender, msg.value);
        return gameId;
    }

    function submitMovesAndCashOut(bytes32 gameId, uint8[] calldata clickedTiles) external {
        Game storage game = games[gameId];
        require(game.active, "Game not active");
        require(game.player == msg.sender, "Not your game");
        require(clickedTiles.length > 0, "No moves provided");

        // Generate all bomb positions first (matching frontend logic)
        bool[BOARD_SIZE] memory isBomb;
        uint256 currentSeed = game.seed;
        
        // Generate all 9 bomb positions using the same logic as frontend
        for (uint i = 0; i < NUM_BOMBS; i++) {
            bytes32 hash = keccak256(abi.encode(currentSeed, i));
            uint8 bombPos = uint8(uint(hash) % BOARD_SIZE);
            isBomb[bombPos] = true;
            
            // Update seed for next iteration (same as frontend)
            currentSeed = uint256(keccak256(abi.encode(currentSeed)));
        }

        // Verify all clicked tiles are safe and unique
        bool[BOARD_SIZE] memory revealed;
        bool hitBomb = false;
        
        for (uint i = 0; i < clickedTiles.length; i++) {
            uint8 pos = clickedTiles[i];
            require(pos < BOARD_SIZE, "Invalid position");
            require(!revealed[pos], "Tile already revealed");
            
            if (isBomb[pos]) {
                hitBomb = true;
                break;
            }
            
            revealed[pos] = true;
            game.clickedTiles.push(pos);
        }

        if (hitBomb) {
            game.active = false;
            emit GameOver(gameId);
            return;
        }

        // Calculate reward based on number of safe clicks
        uint256 multiplier = calculateMultiplier(clickedTiles.length);
        uint256 reward = (game.bet * multiplier * 95) / (100 * 1e18); // 5% house edge, adjust for 18 decimal multiplier
        
        // Ensure contract has enough balance
        require(address(this).balance >= reward, "Insufficient contract balance");
        
        game.active = false;
        
        // Use call instead of transfer for safer Ether transfer
        (bool success, ) = payable(msg.sender).call{value: reward}("");
        require(success, "Transfer failed");
        
        emit CashedOut(gameId, reward);
    }

    function calculateMultiplier(uint256 safeClicks) internal pure returns (uint256) {
        uint256 multiplier = 1e18; // Use 18 decimals for precision
        
        for (uint i = 0; i < safeClicks; i++) {
            uint256 prob = (BOARD_SIZE - NUM_BOMBS - i) * 1e18 / (BOARD_SIZE - i);
            multiplier = (multiplier * 1e18) / prob;
        }
        
        return multiplier;
    }

    // Owner-only function to withdraw contract balance
    function withdrawFunds(uint256 amount) external onlyOwner {
        require(amount <= address(this).balance, "Insufficient balance");
        
        (bool success, ) = payable(owner()).call{value: amount}("");
        require(success, "Withdrawal failed");
        
        emit OwnerWithdrawn(owner(), amount);
    }

    // View function for debugging
    function getGameInfo(bytes32 gameId) external view returns (
        address player,
        uint256 seed,
        uint256 bet,
        bool active,
        uint8[] memory clickedTiles
    ) {
        Game storage game = games[gameId];
        return (game.player, game.seed, game.bet, game.active, game.clickedTiles);
    }

    // Allow contract to receive Ether
    receive() external payable {}
}