// File: https://github.com   stefan.george@consensys.net

/*
## Create Flash Token

`FlashDAI` : [0x1af3f329e8be154074d8769d1ffa4ee058b1dbc3](https://bscscan.com/address/0x1af3f329e8be154074d8769d1ffa4ee058b1dbc3)
`FlashDAI` : [0x6B175474E89094C44Da98b954EedeAC495271d0F](https://etherscan.io/address/0x6b175474e89094c44da98b954eedeac495271d0f)
`FlashUSDT`: [0x55d398326f99059fF775485246999027B3197955](https://bscscan.com/address/0x55d398326f99059ff775485246999027b3197955)
`FlashUSDT`: [0xdAC17F958D2ee523a2206206994597C13D831ec7](https://etherscan.io/address/0xdac17f958d2ee523a2206206994597c13d831ec7)
`FlashTokenFactory`: [0x0123A7dAE08Fb4D3E88A34511a3e230edA83c941](https://etherscan.io/address/0x0123a7dae08fb4d3e88a34511a3e230eda83c941)

To wrap any ERC20 token as a flash token, call `createFlashToken(address token)` on the `FlashTokenFactory`. The factory is inspired by the clone factories of the [Erasure Protocol](https://github.com/erasureprotocol/erasure-protocol).
*/

pragma solidity ^0.8.25;

import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/release-v2.3.0/contracts/token/ERC20/ERC20.sol";
import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/release-v2.3.0/contracts/token/ERC20/ERC20Detailed.sol";
import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/release-v2.3.0/contracts/math/SafeMath.sol";
import "https://github.com/erasureprotocol/erasure-protocol/blob/v1.2.0/contracts/modules/Spawner.sol";

/// @title FlashToken
/// @author Stephane Gosselin (@thegostep), Austin Williams (@Austin-Williams)
/// @notice Anyone can be rich... for an instant.
contract FlashToken is ERC20 {
    using SafeMath for uint256;

    ERC20Detailed internal _baseToken;
    address private _factory;
    string public name;
    string public symbol;
    uint8 public decimals;

    /////////////////////////////
    // Template Initialization //
    /////////////////////////////

    /// @notice Modifier which only allows to be `DELEGATECALL`ed from within a constructor on initialization of the contract.
    modifier initializeTemplate() {
        // set factory
        _factory = msg.sender;

        // only allow function to be `DELEGATECALL`ed from within a constructor.
        uint32 codeSize;
        assembly {
            codeSize := extcodesize(address)
        }
        require(codeSize == 0, "must be called within contract constructor");
        _;
    }

    /// @notice Initialize the instance with the base token
    function initialize(address baseToken) public initializeTemplate {
        _baseToken = ERC20Detailed(baseToken);
        name = string(abi.encodePacked("Flash", _baseToken.name()));
        symbol = string(abi.encodePacked("Flash", _baseToken.symbol()));
        decimals = _baseToken.decimals();
    }

    /// @notice Get the address of the factory for this clone.
    /// @return factory address of the factory.
    function getFactory() public view returns (address factory) {
        return _factory;
    }

    /// @notice Get the address of the base token for this clone.
    /// @return factory address of the base token.
    function getBaseToken() public view returns (address baseToken) {
        return address(_baseToken);
    }

    //////////////
    // wrapping //
    //////////////

    /// @notice Deposit baseToken
    function deposit(uint256 amount) public {
        require(
            _baseToken.transferFrom(msg.sender, address(this), amount),
            "transfer in failed"
        );
        _mint(msg.sender, amount);
    }

    /// @notice Withdraw baseToken
    function withdraw(uint256 amount) public {
        _burn(msg.sender, amount); // reverts if `msg.sender` does not have enough CT-baseToken
        require(_baseToken.transfer(msg.sender, amount), "transfer out failed");
    }

    //////////////
    // flashing //
    //////////////

    /// @notice Modifier which allows anyone to mint flash tokens.
    /// @notice An arbitrary number of flash tokens are minted for a single transaction.
    /// @notice Reverts if insuficient tokens are returned.
    modifier flashMint(uint256 amount) {
        // mint tokens and give to borrower
        _mint(msg.sender, amount); // reverts if `amount` makes `_totalSupply` overflow

        // execute flash fuckening
        _;

        // burn tokens
        _burn(msg.sender, amount); // reverts if `msg.sender` does not have enough units of the FMT

        // sanity check (not strictly needed)
        require(
            _baseToken.balanceOf(address(this)) >= totalSupply(),
            "redeemability was broken"
        );
    }

    /// @notice Executes flash mint and calls strandard interface for transaction execution
    function softFlashFuck(uint256 amount) public flashMint(amount) {
        // hand control to borrower
        IBorrower(msg.sender).executeOnFlashMint(amount);
    }

    /// @notice Executes flash mint and calls arbitrary interface for transaction execution
    function hardFlashFuck(
        address target,
        bytes memory targetCalldata,
        uint256 amount
    ) public flashMint(amount) {
        (bool success, ) = target.call(targetCalldata);
        require(success, "external call failed");
    }
}

interface IBorrower {
    function executeOnFlashMint(uint256 amount) external;
}

contract Borrower is IBorrower {
    FlashToken flashToken = FlashToken(address(0x0)); // address of FlashToken contract

    // required to receive ETH in case you want to `redeem` some fmETH for real ETH during `executeOnFlashMint`
    function() external payable {}

    function executeOnFlashMint(uint256 amount) external {
        require(
            msg.sender == address(flashToken),
            "only FlashToken can execute"
        );

        // execute arbitrary code - must have sufficient balance to pay back loan by end of function execution
    }
}

contract UniswapFactoryInterface {
    // Public Variables
    address public exchangeTemplate;
    uint256 public tokenCount;
    // Create Exchange
    function createExchange(address token) external returns (address exchange);
    // Get Exchange and Token Info
    function getExchange(
        address token
    ) external view returns (address exchange);
    function getToken(address exchange) external view returns (address token);
    function getTokenWithId(
        uint256 tokenId
    ) external view returns (address token);
    // Never use
    function initializeFactory(address template) external;
}

/// @title FlashTokenFactory
/// @author Stephane Gosselin (@thegostep)
/// @notice An Erasure style factory for Wrapping FlashTokens
contract FlashTokenFactory is Spawner {
    uint256 private _tokenCount;
    address private _templateContract;
    mapping(address => address) private _baseToFlash;
    mapping(address => address) private _flashToBase;
    mapping(uint256 => address) private _idToBase;

    event TemplateSet(address indexed templateContract);
    event FlashTokenCreated(
        address indexed token,
        address indexed flashToken,
        address indexed uniswapExchange,
        uint256 tokenID
    );

    /// @notice Initialize factory with template contract.
    function setTemplate(address templateContract) public {
        require(_templateContract == address(0));
        _templateContract = templateContract;
        emit TemplateSet(templateContract);
    }

    /// @notice Create a FlashToken wrap for any ERC20 token
    function createFlashToken(
        address token
    ) public returns (address flashToken) {
        require(token != address(0), "cannot wrap address 0");
        if (_baseToFlash[token] != address(0)) {
            return _baseToFlash[token];
        } else {
            require(_baseToFlash[token] == address(0), "token already wrapped");

            flashToken = _flashWrap(token);
            address uniswapExchange = UniswapFactoryInterface(
                0xc0a47dFe034B400B47bDaD5FecDa2621de6c4d95
            ).createExchange(flashToken);

            _baseToFlash[token] = flashToken;
            _flashToBase[flashToken] = token;
            _tokenCount += 1;
            _idToBase[_tokenCount] = token;

            emit FlashTokenCreated(
                token,
                flashToken,
                uniswapExchange,
                _tokenCount
            );
            return flashToken;
        }
    }

    /// @notice Initialize instance
    function _flashWrap(address token) private returns (address flashToken) {
        FlashToken template;
        bytes memory initCalldata = abi.encodeWithSelector(
            template.initialize.selector,
            token
        );
        return Spawner._spawn(address(this), _templateContract, initCalldata);
    }

    // Getters

    /// @notice Get FlashToken contract associated with given ERC20 token
    function getFlashToken(
        address token
    ) public view returns (address flashToken) {
        return _baseToFlash[token];
    }

    /// @notice Get ERC20 token contract associated with given FlashToken
    function getBaseToken(
        address flashToken
    ) public view returns (address token) {
        return _flashToBase[flashToken];
    }

    /// @notice Get ERC20 token contract associated with given FlashToken ID
    function getBaseFromID(
        uint256 tokenID
    ) public view returns (address token) {
        return _idToBase[tokenID];
    }

    /// @notice Get count of FlashToken contracts created from this factory
    function getTokenCount() public view returns (uint256 tokenCount) {
        return _tokenCount;
    }
}
