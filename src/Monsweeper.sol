// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@pythnetwork/entropy-sdk-solidity/IEntropy.sol";
import "@pythnetwork/entropy-sdk-solidity/IntropyConsumer.soEl";

contract SecureMinesweeper is Ownable, ReentrancyGuard, IEntropyConsumer {
    IEntropy public immutable entropy;
    address public immutable entropyProvider;
    
    enum GameDifficulty { NORMAL, GOD_OF_WAR }
    
    struct Game {
        address player;
        uint256 bet;
        bool active;
        bool randomnessRevealed;
        bytes32 finalRandomness;
        uint8[] clickedTiles;
        GameDifficulty difficulty;
        uint256 startTimestamp;
    }
    
    struct PlayerStats {
        uint256 totalEarned;
        uint256 totalLost;
        uint256 gamesPlayed;
        uint256 gamesWon;
    }
    
    mapping(bytes32 => Game) public games;
    mapping(address => PlayerStats) public playerStats;
    mapping(address => bytes32[]) public playerActiveGames;
    mapping(uint64 => bytes32) public sequenceNumberToGameId; // Map sequence numbers to game IDs
    
    // Game constants
    uint8 constant BOARD_SIZE = 36;
    uint8 constant NORMAL_BOMBS = 9;
    uint8 constant GOD_OF_WAR_BOMBS = 12;
    uint256 constant POOL_SAFETY_THRESHOLD = 30;
    uint256 constant FORCE_CASHOUT_MULTIPLIER = 50;
    uint256 constant GOD_OF_WAR_PAYOUT_BONUS = 150;
    
    event GameStarted(bytes32 gameId, address player, uint256 bet, GameDifficulty difficulty);
    event RandomnessRequested(bytes32 gameId, uint64 sequenceNumber);
    event RandomnessRevealed(bytes32 gameId, bytes32 randomValue);
    event CashedOut(bytes32 gameId, uint256 reward);
    event GameOver(bytes32 gameId);
    event ForcedCashout(bytes32 gameId, uint256 reward, string reason);
    event OwnerWithdrawn(address indexed owner, uint256 amount);
    event Debug(string message, bytes32 gameId);
    
    constructor(
        address _entropy,
        address _entropyProvider
    ) Ownable(msg.sender) {
        require(_entropy != address(0), "Invalid entropy address");
        require(_entropyProvider != address(0), "Invalid provider address");
        entropy = IEntropy(_entropy);
        entropyProvider = _entropyProvider;
    }
    
    // This is required by IEntropyConsumer
    function getEntropy() internal view override returns (address) {
        return address(entropy);
    }
    
    function startGame(
        bytes32 userRandomNumber,
        GameDifficulty difficulty
    ) external payable returns (bytes32) {
        require(msg.value > 0, "Bet must be greater than 0");
        require(userRandomNumber != bytes32(0), "Invalid user random number");
        require(getPlayerActiveGameCount(msg.sender) == 0, "Finish current game first");
        
        // Get entropy fee
        uint128 entropyFee;
        try entropy.getFee(entropyProvider) returns (uint128 _fee) {
            entropyFee = _fee;
        } catch Error(string memory reason) {
            emit Debug(string(abi.encodePacked("Entropy fee failed: ", reason)), bytes32(0));
            revert(string(abi.encodePacked("Entropy fee failed: ", reason)));
        } catch {
            emit Debug("Entropy provider not available", bytes32(0));
            revert("Entropy provider not available");
        }
        
        uint256 actualBet = msg.value - entropyFee;
        require(actualBet > 0, "Bet amount too small after entropy fee");
        require(actualBet <= getMaxBetAllowed(), "Bet exceeds pool safety limit");
        
        // Create unique game ID
        bytes32 gameId = keccak256(abi.encode(msg.sender, userRandomNumber, block.timestamp, difficulty));
        Game storage game = games[gameId];
        require(!game.active, "Game already exists");
        
        // Request randomness from Pyth Entropy using callback method
        uint64 sequenceNumber;
        try entropy.requestWithCallback{value: entropyFee}(
            entropyProvider,
            userRandomNumber
        ) returns (uint64 _sequenceNumber) {
            sequenceNumber = _sequenceNumber;
        } catch Error(string memory reason) {
            emit Debug(string(abi.encodePacked("Entropy request failed: ", reason)), gameId);
            revert(string(abi.encodePacked("Entropy request failed: ", reason)));
        } catch {
            emit Debug("Failed to request randomness", gameId);
            revert("Failed to request randomness");
        }
        
        // Initialize game
        game.player = msg.sender;
        game.bet = actualBet;
        game.active = true;
        game.randomnessRevealed = false;
        game.difficulty = difficulty;
        game.startTimestamp = block.timestamp;
        delete game.clickedTiles;
        
        // Map sequence number to game ID for callback
        sequenceNumberToGameId[sequenceNumber] = gameId;
        
        playerActiveGames[msg.sender].push(gameId);
        playerStats[msg.sender].totalLost += actualBet;
        playerStats[msg.sender].gamesPlayed += 1;
        
        emit GameStarted(gameId, msg.sender, actualBet, difficulty);
        emit RandomnessRequested(gameId, sequenceNumber);
        
        return gameId;
    }
    
    // This callback is automatically called by Pyth when randomness is fulfilled
    function entropyCallback(
        uint64 sequenceNumber,
        address, // provider address - not used
        bytes32 randomValue
    ) internal override {
        bytes32 gameId = sequenceNumberToGameId[sequenceNumber];
        require(gameId != bytes32(0), "Invalid sequence number");
        
        Game storage game = games[gameId];
        require(game.active, "Game not active");
        require(!game.randomnessRevealed, "Randomness already revealed");
        
        game.finalRandomness = randomValue;
        game.randomnessRevealed = true;
        
        emit RandomnessRevealed(gameId, randomValue);
        
        // Clean up mapping
        delete sequenceNumberToGameId[sequenceNumber];
    }
    
    function submitMovesAndCashOut(
        bytes32 gameId,
        uint8[] calldata clickedTiles
    ) external nonReentrant {
        Game storage game = games[gameId];
        require(game.active, "Game not active");
        require(game.player == msg.sender, "Not your game");
        require(game.randomnessRevealed, "Randomness not revealed yet");
        require(clickedTiles.length > 0, "No moves provided");
        
        uint8 numBombs = game.difficulty == GameDifficulty.GOD_OF_WAR ? GOD_OF_WAR_BOMBS : NORMAL_BOMBS;
        uint256 maxSafeTiles = BOARD_SIZE - numBombs;
        
        require(clickedTiles.length <= maxSafeTiles, "Too many moves");
        
        bool[BOARD_SIZE] memory isBomb = generateBombPositions(game.finalRandomness, numBombs);
        
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
            _endGame(gameId, false);
            emit GameOver(gameId);
            return;
        }
        
        uint256 baseMultiplier = calculateMultiplier(clickedTiles.length, numBombs);
        uint256 multiplier = baseMultiplier;
        
        if (game.difficulty == GameDifficulty.GOD_OF_WAR) {
            multiplier = (baseMultiplier * GOD_OF_WAR_PAYOUT_BONUS) / 100;
        }
        
        uint256 potentialReward = (game.bet * multiplier) / 1e18;
        
        string memory forcedReason = "";
        bool forcedCashout = false;
        
        uint256 poolThreshold = (address(this).balance * POOL_SAFETY_THRESHOLD) / 100;
        if (potentialReward > poolThreshold) {
            forcedCashout = true;
            forcedReason = "Pool safety threshold reached";
            potentialReward = poolThreshold;
        }
        
        if (multiplier > FORCE_CASHOUT_MULTIPLIER * 1e18) {
            forcedCashout = true;
            forcedReason = "Maximum multiplier reached";
        }
        
        uint256 reward = (potentialReward * 95) / 100;
        
        require(address(this).balance >= reward, "Insufficient contract balance");
        
        playerStats[msg.sender].totalEarned += reward;
        playerStats[msg.sender].gamesWon += 1;
        
        _endGame(gameId, true);
        
        (bool success, ) = payable(msg.sender).call{value: reward}("");
        require(success, "Transfer failed");
        
        if (forcedCashout) {
            emit ForcedCashout(gameId, reward, forcedReason);
        } else {
            emit CashedOut(gameId, reward);
        }
    }
    
    function generateBombPositions(
        bytes32 randomness,
        uint8 numBombs
    ) internal pure returns (bool[BOARD_SIZE] memory) {
        bool[BOARD_SIZE] memory isBomb;
        uint256 currentSeed = uint256(randomness);
        uint8 bombsPlaced = 0;
        uint8 attempts = 0;
        
        while (bombsPlaced < numBombs && attempts < 200) {
            bytes32 hash = keccak256(abi.encode(currentSeed, bombsPlaced, attempts));
            uint8 bombPos = uint8(uint256(hash) % BOARD_SIZE);
            
            if (!isBomb[bombPos]) {
                isBomb[bombPos] = true;
                bombsPlaced++;
            }
            
            currentSeed = uint256(keccak256(abi.encode(currentSeed, attempts)));
            attempts++;
        }
        
        return isBomb;
    }
    
    function calculateMultiplier(
        uint256 safeClicks,
        uint8 numBombs
    ) internal pure returns (uint256) {
        uint256 multiplier = 1e18;
        uint256 safeTiles = BOARD_SIZE - numBombs;
        
        for (uint i = 0; i < safeClicks; i++) {
            uint256 prob = (safeTiles - i) * 1e18 / (BOARD_SIZE - i);
            multiplier = (multiplier * 1e18) / prob;
        }
        
        return multiplier;
    }
    
    function _endGame(bytes32 gameId, bool won) internal {
        Game storage game = games[gameId];
        game.active = false;
        
        bytes32[] storage activeGames = playerActiveGames[game.player];
        for (uint i = 0; i < activeGames.length; i++) {
            if (activeGames[i] == gameId) {
                activeGames[i] = activeGames[activeGames.length - 1];
                activeGames.pop();
                break;
            }
        }
    }
    
    function getPlayerStats(address player) external view returns (PlayerStats memory) {
        return playerStats[player];
    }
    
    function getPlayerActiveGameCount(address player) public view returns (uint256) {
        return playerActiveGames[player].length;
    }
    
    function getPlayerActiveGames(address player) external view returns (bytes32[] memory) {
        return playerActiveGames[player];
    }
    
    function getMaxBetAllowed() public view returns (uint256) {
        uint256 poolBalance = address(this).balance;
        return (poolBalance * POOL_SAFETY_THRESHOLD) / 100;
    }
    
    function getGameInfo(bytes32 gameId) external view returns (
        address player,
        uint256 bet,
        bool active,
        bool randomnessRevealed,
        uint8[] memory clickedTiles,
        GameDifficulty difficulty,
        uint256 startTimestamp
    ) {
        Game storage game = games[gameId];
        return (
            game.player,
            game.bet,
            game.active,
            game.randomnessRevealed,
            game.clickedTiles,
            game.difficulty,
            game.startTimestamp
        );
    }
    
    function calculatePotentialReward(
        bytes32 gameId,
        uint8 additionalClicks
    ) external view returns (uint256) {
        Game storage game = games[gameId];
        require(game.active, "Game not active");
        
        uint8 numBombs = game.difficulty == GameDifficulty.GOD_OF_WAR ? GOD_OF_WAR_BOMBS : NORMAL_BOMBS;
        uint256 totalClicks = game.clickedTiles.length + additionalClicks;
        
        uint256 baseMultiplier = calculateMultiplier(totalClicks, numBombs);
        uint256 multiplier = baseMultiplier;
        
        if (game.difficulty == GameDifficulty.GOD_OF_WAR) {
            multiplier = (baseMultiplier * GOD_OF_WAR_PAYOUT_BONUS) / 100;
        }
        
        uint256 potentialReward = (game.bet * multiplier * 95) / (100 * 1e18);
        
        uint256 poolThreshold = (address(this).balance * POOL_SAFETY_THRESHOLD) / 100;
        if (potentialReward > poolThreshold) {
            potentialReward = poolThreshold;
        }
        
        return potentialReward;
    }
    
    function shouldForceCashout(bytes32 gameId, uint8 additionalClicks) external view returns (bool, string memory) {
        Game storage game = games[gameId];
        require(game.active, "Game not active");
        
        uint8 numBombs = game.difficulty == GameDifficulty.GOD_OF_WAR ? GOD_OF_WAR_BOMBS : NORMAL_BOMBS;
        uint256 totalClicks = game.clickedTiles.length + additionalClicks;
        
        uint256 baseMultiplier = calculateMultiplier(totalClicks, numBombs);
        uint256 multiplier = baseMultiplier;
        
        if (game.difficulty == GameDifficulty.GOD_OF_WAR) {
            multiplier = (baseMultiplier * GOD_OF_WAR_PAYOUT_BONUS) / 100;
        }
        
        uint256 potentialReward = (game.bet * multiplier) / 1e18;
        uint256 poolThreshold = (address(this).balance * POOL_SAFETY_THRESHOLD) / 100;
        
        if (potentialReward > poolThreshold) {
            return (true, "Pool safety threshold would be exceeded");
        }
        
        if (multiplier > FORCE_CASHOUT_MULTIPLIER * 1e18) {
            return (true, "Maximum multiplier reached");
        }
        
        return (false, "");
    }
    
    function withdrawFunds(uint256 amount) external onlyOwner {
        require(amount <= address(this).balance, "Insufficient balance");
        
        (bool success, ) = payable(owner()).call{value: amount}("");
        require(success, "Withdrawal failed");
        
        emit OwnerWithdrawn(owner(), amount);
    }
    
    function emergencyEndGame(bytes32 gameId) external onlyOwner {
        Game storage game = games[gameId];
        require(game.active, "Game not active");
        
        _endGame(gameId, false);
        
        (bool success, ) = payable(game.player).call{value: game.bet}("");
        require(success, "Refund failed");
        
        emit GameOver(gameId);
    }
    
    function checkEntropyProvider() external view returns (uint128 fee) {
        return entropy.getFee(entropyProvider);
    }
    
    function checkEntropyContract() external view returns (address) {
        return address(entropy);
    }
    
    function getEntropyProvider() external view returns (address) {
        return entropyProvider;
    }
    
    function getRequiredAmounts() external view returns (uint128 entropyFee, uint256 maxBetAllowed) {
        entropyFee = entropy.getFee(entropyProvider);
        maxBetAllowed = getMaxBetAllowed();
    }
    
    // Check if game is waiting for randomness
    function isWaitingForRandomness(bytes32 gameId) external view returns (bool) {
        Game storage game = games[gameId];
        return game.active && !game.randomnessRevealed;
    }
    
    receive() external payable {}
}