// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @dev A token in the manner of the stock tokens of Robinhood on Robinhood Chain (CHECKED 7 Nov
/// 2026 on the NVDA token 0xd0601ce157db5bdc3162bbac2a2c8af5320d9eec): a plain ERC-20 whose
/// issuer can block a wallet, pause every transfer, and burn from any wallet.
contract MockStockToken {
    string public constant name = "NVIDIA test token";
    string public constant symbol = "NVDA";
    uint8 public constant decimals = 18;

    uint256 public totalSupply;
    bool public paused;
    mapping(address account => uint256 amount) public balanceOf;
    mapping(address account => bool blocked) public isBlocked;
    mapping(address account => mapping(address spender => uint256 amount)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    error AccountBlocked(address account);
    error TokenPaused();
    error InsufficientBalance(address account, uint256 balance, uint256 needed);

    function mint(address to, uint256 amount) external {
        totalSupply += amount;
        balanceOf[to] += amount;
        emit Transfer(address(0), to, amount);
    }

    function adminBurn(address from, uint256 amount) external {
        balanceOf[from] -= amount;
        totalSupply -= amount;
        emit Transfer(from, address(0), amount);
    }

    function setBlocked(address account, bool blocked) external {
        isBlocked[account] = blocked;
    }

    function setPaused(bool value) external {
        paused = value;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _move(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        allowance[from][msg.sender] -= amount;
        _move(from, to, amount);
        return true;
    }

    function _move(address from, address to, uint256 amount) private {
        if (paused) revert TokenPaused();
        if (isBlocked[from]) revert AccountBlocked(from);
        if (isBlocked[to]) revert AccountBlocked(to);
        uint256 balance = balanceOf[from];
        if (balance < amount) revert InsufficientBalance(from, balance, amount);
        balanceOf[from] = balance - amount;
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
    }
}

/// @dev A token whose transfer returns false instead of reverting.
contract FalseToken {
    mapping(address account => uint256 amount) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function transfer(address, uint256) external pure returns (bool) {
        return false;
    }
}

/// @dev A token whose transfer returns nothing, as USDT on Ethereum does.
contract NoReturnToken {
    mapping(address account => uint256 amount) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function transfer(address to, uint256 amount) external {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
    }
}

/// @dev The calls that `ReentrantToken` makes back into Earn.
interface IEarnClaim {
    function claim(address account, uint256 cumulative, bytes32[] calldata proof) external returns (uint256);
}

/// @dev A token that calls `claim` of Earn again from inside each transfer, once, and keeps
/// whether that call paid anything.
contract ReentrantToken {
    mapping(address account => uint256 amount) public balanceOf;

    address public target;
    address public account;
    uint256 public cumulative;
    bytes32[] public proof;
    bool public entered;
    bool public innerPaid;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function arm(address target_, address account_, uint256 cumulative_, bytes32[] calldata proof_) external {
        target = target_;
        account = account_;
        cumulative = cumulative_;
        proof = proof_;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        if (target != address(0) && !entered) {
            entered = true;
            try IEarnClaim(target).claim(account, cumulative, proof) returns (uint256 paid) {
                innerPaid = paid > 0;
            } catch {
                innerPaid = false;
            }
        }
        return true;
    }
}
