// SPDX-License-Identifier: GPL-3.0

pragma solidity >=0.7.0 <0.9.0;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

enum Status {
    PLAY, FOLD, ALL
}

struct Table {
    address admin;       // open this table
    uint minChip;        // min chip small blind
    uint playerCount;      // player number
    address[10] players; // max 10 players
    mapping(address => uint) playerChips; // 10x minChip - 1000 minChip
    uint dealer;         // next dealer
    bool gameOn;         // yes game on
}

struct Game {
    mapping(address => uint) gameChips;
    Status[] gameStatus;
    address winner;
    uint round;     // how many round
    uint turn;      // who's turn
    uint leadTurn;
    uint leadChip;
    uint raiseSize;
    uint tableId;
    uint playing;
    bool ended;
}

/**
 * @title Poker
 * @dev Poker - Sky
 * @custom:dev-run-script ./scripts/deploy_with_ethers.ts
 */
contract Poker is Ownable {
    Table[] public tables;
    Game[] public games;
    ERC20 public pokerToken;                  // use what token
    mapping(address => uint) public adminTable;

    constructor(address token) {
        pokerToken = ERC20(token);
    }

    function tableCount() public view returns (uint) {
        return tables.length;
    }

    function gameCount() public view returns (uint) {
        return games.length;
    }

    function playerCount(uint tableId) public view returns (uint) {
        return tables[tableId].playerCount;
    }

    function openTable(uint minChip) public returns (uint tableId){
        Table storage newTable = tables.push();
        newTable.admin = msg.sender;
        newTable.minChip = minChip;
        newTable.playerCount = 0;
        newTable.dealer = 0;
        newTable.gameOn = false;
        tableId = tables.length - 1;
        adminTable[msg.sender] = tableId;
    }

    function joinTable(uint tableId, uint chips) public {
        require(pokerToken.transferFrom(msg.sender, address(this), chips), "Token transfer failed");
        Table storage table = tables[tableId];
        require(table.gameOn == false, "Game already started");
        require(table.playerChips[msg.sender] == 0, "Already player");
        require(chips >= table.minChip * 10 && chips <= table.minChip * 1000, "Invalid chips");
        require(table.players.length < 10, "Table is full");
        table.players[table.playerCount++] = msg.sender;
        table.playerChips[msg.sender] = chips;
    }

    function joinAdmin(address admin, uint chips) public {
        uint tableId = adminTable[admin];
        joinTable(tableId, chips);
    }

    function exitTable(uint tableId) public {
        Table storage table = tables[tableId];
        require(table.gameOn == false, "Game already started");
        for (uint i = 0; i < table.players.length; i++) {
            if (msg.sender == table.players[i]) {
                kick(tableId, i);
                return;
            }
        }
        revert("Not a player");
    }

    function kickPlayer(uint tableId, address player) public {
        Table storage table = tables[tableId];
        require(table.admin == msg.sender, "Not Table Admin");
        require(table.gameOn == false, "Game already started");
        for (uint i = 0; i < table.players.length; i++) {
            if (player == table.players[i]) {
                kick(tableId, i);
                return;
            }
        }
        revert("Not a player");
    }

    function startGame(uint tableId) public returns (uint turn){
        Table storage table = tables[tableId];
        require(table.admin == msg.sender, "Not Table Admin");
        require(table.gameOn == false, "Game already started");
        for (uint i = 0; i < table.playerCount;) {
            if (table.playerChips[table.players[i]] < 4 * table.minChip) {
                kick(tableId, i);
            } else {
                i++;
            }
        }
        require(table.playerCount >= 3, "Game player must more than 3");

        Game storage newGame = games.push();
        newGame.tableId = tableId;
        newGame.round = 0;
        
        // small blind
        newGame.turn = table.dealer;
        newGame.turn = roundAdd(table.playerCount, newGame.turn, 1);
        address player = table.players[newGame.turn];
        newGame.gameChips[player] = table.minChip;
        table.playerChips[player] -= table.minChip;
        // big blind
        newGame.turn = roundAdd(table.playerCount, newGame.turn, 1);
        player = table.players[newGame.turn];
        newGame.gameChips[player] = table.minChip << 1;
        table.playerChips[player] -= table.minChip << 1;
        newGame.leadChip = table.minChip << 1;
        newGame.leadTurn = newGame.turn;
        newGame.raiseSize = table.minChip;
        // under gun
        newGame.turn = roundAdd(table.playerCount, newGame.turn, 1);
        turn = newGame.turn;

        // set players
        for (uint i=0; i<table.playerCount;i++) {
            newGame.gameStatus[i] = Status.PLAY;
        } 
        
        // set params
    
        newGame.playing = table.playerCount;
        newGame.winner = address(0);
        newGame.ended = false;
        table.gameOn = true;
    }

    function fold(uint gameId) public returns (uint nextTurn, uint chips) {
        Game storage game = games[gameId];
        require(game.ended == false, "Game ended");
        uint turn = game.turn;
        require(game.gameStatus[turn] == Status.PLAY, "Not playing"); // check status

        // player
        uint tableId = game.tableId;
        Table storage table = tables[tableId];
        address player = table.players[turn];
        require(msg.sender == player, "Not your turn"); // check player

        game.gameStatus[turn] = Status.FOLD;
        game.playing --;

        // returns
        nextTurn = roundNext(game.gameStatus, turn, game.leadTurn);
        chips = game.gameChips[player];

        if (game.playing == 1) {
            game.ended = true; // need settle
        } else {
            if (nextTurn == table.playerCount) {
                if (game.round == 3) {
                    game.ended = true; // need settle
                } else {
                    nextTurn = nextRound(game, table.dealer);
                }
            } else {
                game.turn = nextTurn;
            } 
        } 
    }

    function call(uint gameId) public returns (uint nextTurn, uint chips) {
        Game storage game = games[gameId];
        require(game.ended == false, "Game ended");
        uint turn = game.turn;
        require(game.gameStatus[turn] == Status.PLAY, "Not playing"); // check status

        uint tableId = game.tableId;
        Table storage table = tables[tableId];
        address player = table.players[turn];
        require(msg.sender == player, "Not your turn"); // check sender

        // if leadChip is 0, check
        if (game.leadChip == 0) {
            nextTurn = roundNext(game.gameStatus, turn, game.leadTurn);
            chips = game.gameChips[player];
            return (nextTurn, chips);
        }

        if (table.playerChips[player]<game.leadChip) {
            game.gameChips[player] += table.playerChips[player];
            table.playerChips[player] = 0;
            game.gameStatus[turn] = Status.ALL;
            game.playing --;
        } else {
            game.gameChips[player] += game.leadChip;
            table.playerChips[player] -= game.leadChip;
        }

        nextTurn = roundNext(game.gameStatus, turn, game.leadTurn);
        chips = game.gameChips[player];

        if (game.playing == 1) {
            game.ended = true; // need settle
        } else {
            if (nextTurn == table.playerCount) {
                if (game.round == 3) {
                    game.ended = true; // need settle
                } else {
                    nextTurn = nextRound(game, table.dealer);
                }
            } else {
                game.turn = nextTurn;
            } 
        } 
    }

    function raise(uint gameId, uint moreChips) public returns (uint nextTurn, uint chips) {
        Game storage game = games[gameId];
        require(game.ended == false, "Game ended");
        uint turn = game.turn;
        require(game.gameStatus[turn] == Status.PLAY, "Not playing"); // check status

        uint tableId = game.tableId;
        Table storage table = tables[tableId];
        address player = table.players[turn];
        require(msg.sender == player, "Not your turn"); // check sender
        require(table.playerChips[player] >= moreChips, "Insufficient chips");
        require(moreChips >= game.leadChip + game.raiseSize, "no more than chips");

        game.raiseSize = moreChips - game.leadChip;
        game.leadChip = moreChips;
        game.leadTurn = turn;
       
        if (table.playerChips[player] == game.leadChip) {
            game.gameChips[player] += table.playerChips[player];
            table.playerChips[player] = 0;
            game.gameStatus[turn] = Status.ALL;
            game.playing --;
        } else {
            game.gameChips[player] += game.leadChip;
            table.playerChips[player] -= game.leadChip;
        }

        nextTurn = roundNext(game.gameStatus, turn, game.leadTurn);
        chips = game.gameChips[player];

        if (game.playing == 1) {
            game.ended = true; // need settle
        } else {
            if (nextTurn == table.playerCount) {
                if (game.round == 3) {
                    game.ended = true; // need settle
                } else {
                    nextTurn = nextRound(game, table.dealer);
                }
            } else {
                game.turn = nextTurn;
            } 
        }
    }

    function allin(uint gameId) public returns (uint nextTurn, uint chips) {
        Game storage game = games[gameId];
        uint tableId = game.tableId;
        Table storage table = tables[tableId];
        uint allChips = table.playerChips[msg.sender];
        return raise(gameId, allChips);
    }

    function nextRound(Game storage game, uint dealer) internal returns (uint turn) {
        game.turn = roundNext(game.gameStatus, dealer, dealer);
        game.leadTurn = game.turn;
        game.leadChip = 0;
        game.raiseSize = 0;
        game.round ++;
        turn = game.turn;
    }

    function settle(uint gameId, address winner) public {
        Game storage game = games[gameId];
        uint tableId = game.tableId;
        Table storage table = tables[tableId];
        require(table.admin == msg.sender, "Not Table Admin");
        require(game.ended == true, "Game not ended");
        require(game.gameStatus[game.turn] != Status.FOLD , "Not playing"); 

        uint profit = game.gameChips[winner];
        for (uint i = 0; i < table.playerCount; i++) {
            address player = table.players[i];
            if (game.gameChips[player] > profit) {
                table.playerChips[winner] += profit;
                uint left = game.gameChips[player] - profit;
                table.playerChips[player] += left;
            } else {
                table.playerChips[winner] += game.gameChips[player];
            }
            
        }

        table.dealer = roundAdd(table.playerCount, table.dealer, 1);
        table.gameOn = false;
    }


    function kick(uint tableId, uint playerId) internal {
        Table storage table = tables[tableId];
        require(table.gameOn == false, "Game already started");
        address player = table.players[playerId];
        // transfer back token
        pokerToken.transferFrom(address(this), player, table.playerChips[player]);
        delete table.playerChips[player];

        for (uint i = playerId; i < table.playerCount; i++) {
            table.players[i] = table.players[i+1];
        }
        table.playerCount--;
    }

    // if next round, return max player
    function roundNext(Status[] memory status, uint turn, uint lead) internal pure returns (uint next) {
        uint i = roundAdd(status.length, turn, 1);
        while (i != turn) {
            if (i == lead) {
                return status.length;
            }
            if (status[i] == Status.PLAY) {
                return i;
            }
            i = roundAdd(status.length, i, 1);
        }
        revert("roundNext no player");
    }

    function roundAdd(uint ttl, uint a, uint b) internal pure returns (uint ret) {
        ret = (a + b) % ttl;
    }

    function distance(uint ttl, uint a, uint b) internal pure returns (uint dist) {
        if (b > a) {
            dist = b - a;
        } else {
            dist = ttl - a + b;
        }
    }
}