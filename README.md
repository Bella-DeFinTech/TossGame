# TossGame

Powered by [Randcast](https://docs.arpanetwork.io/randcast), TossGame is an onchain game that allows users to toss a coin and win prizes. The game uses gasless transactions through EIP712 signatures for better UX.

## Overview

TossGame supports both ETH and ERC20 tokens, with three main operations:

- Deposit tokens with permit
- Toss coin with signature
- Withdraw tokens with signature

## Contract Deployment

```shell
$ forge build --sizes
$ FOUNDRY_PROFILE=test forge test
```

## Integration Guide

### EIP712 Domain

```typescript
const domain = {
  name: "TossGame",
  version: "1",
  chainId: chainId,
  verifyingContract: gameAddress,
};
```

### 1. Deposit Tokens (ERC20)

#### Permit Type Definition

```typescript
const PERMIT_TYPE = {
  Permit: [
    { name: "owner", type: "address" },
    { name: "spender", type: "address" },
    { name: "value", type: "uint256" },
    { name: "nonce", type: "uint256" },
    { name: "deadline", type: "uint256" },
  ],
};
```

#### Generate Permit Signature

```typescript
async function getPermitSignature(
  token: Contract,
  owner: string,
  spender: string,
  value: BigNumber,
  deadline: number
) {
  const nonce = await token.nonces(owner);

  const permitDomain = {
    name: await token.name(),
    version: "1",
    chainId: chainId,
    verifyingContract: token.address,
  };

  const signature = await signer._signTypedData(permitDomain, PERMIT_TYPE, {
    owner,
    spender,
    value,
    nonce,
    deadline,
  });

  return ethers.utils.splitSignature(signature);
}
```

Note:

1. Owner here is the user who is depositing the tokens. Spender is the game contract address.
2. All amounts/values(and in the context below) are in token decimals. like input with 100, the token decimal is 18, then the amount is 100e18.

### 2. Toss Coin

#### Type Definition

```typescript
const TYPES = {
  // Matches exact TOSS_TYPEHASH from contract
  TossCoin: [
    { name: "user", type: "address" },
    { name: "token", type: "address" },
    { name: "tokenAmount", type: "uint256" },
    { name: "tokenPrice", type: "uint256" },
    { name: "nonce", type: "uint256" },
    { name: "deadline", type: "uint256" },
    { name: "tossResult", type: "bool" },
  ],
};
```

#### Generate Toss Signature

```typescript
async function getTossSignature(
  game: Contract,
  user: string,
  token: string,
  amount: BigNumber,
  tokenPrice: BigNumber,
  tossResult: boolean
) {
  const domain = {
    name: "TossGame",
    version: "1",
    chainId: await getChainId(),
    verifyingContract: game.address,
  };

  const nonce = await game.nonces(user);
  const deadline = Math.floor(Date.now() / 1000) + 3600;

  // Match exact order from TOSS_TYPEHASH
  const value = {
    user,
    token,
    tokenAmount: amount,
    tokenPrice,
    nonce,
    deadline,
    tossResult,
  };

  const signature = await signer._signTypedData(
    domain,
    { TossCoin: TYPES.TossCoin },
    value
  );

  return {
    ...value,
    ...ethers.utils.splitSignature(signature),
  };
}
```

### 3. Withdraw

#### Type Definition

```typescript
const TYPES = {
  // Matches exact WITHDRAW_TYPEHASH from contract
  Withdraw: [
    { name: "user", type: "address" },
    { name: "token", type: "address" },
    { name: "tokenAmount", type: "uint256" },
    { name: "tokenPrice", type: "uint256" },
    { name: "nonce", type: "uint256" },
    { name: "deadline", type: "uint256" },
  ],
};
```

#### Generate Withdraw Signature

```typescript
async function getWithdrawSignature(
  game: Contract,
  user: string,
  token: string,
  amount: BigNumber,
  tokenPrice: BigNumber
) {
  const domain = {
    name: "TossGame",
    version: "1",
    chainId: await getChainId(),
    verifyingContract: game.address,
  };

  const nonce = await game.nonces(user);
  const deadline = Math.floor(Date.now() / 1000) + 3600;

  // Match exact order from WITHDRAW_TYPEHASH
  const value = {
    user,
    token,
    tokenAmount: amount,
    tokenPrice,
    nonce,
    deadline,
  };

  const signature = await signer._signTypedData(
    domain,
    { Withdraw: TYPES.Withdraw },
    value
  );

  return {
    ...value,
    ...ethers.utils.splitSignature(signature),
  };
}
```

## Required Inputs

### Token Price

- Get from price oracle or CEX at the time of user request, it's better to use twap
  - Example: liquidity of b3 is concentrated in coinbase, but the desired token to exchange(bnb) is not supported in coinbase, so query supported cryptocurrencies and exchange-rate from coingecko
    - query supported cryptocurrencies: https://docs.coingecko.com/reference/simple-supported-currencies
    - query exchange-rate: https://docs.coingecko.com/reference/simple-price
    - Rate Limit: https://docs.coingecko.com/reference/common-errors-rate-limit
- Then scaled by 1e18
  - Example: If 1 TOKEN = 0.01 ETH, tokenPrice = ethers.utils.parseEther('0.01')
  - Example: Otherwise, if 1 bnb = 77235 b3, tokenPrice = 1e18 / 77235

### Gas Overheads

```solidity
DEPOSIT_OPERATOR_GAS_OVERHEAD = 120000
WITHDRAW_OPERATOR_GAS_OVERHEAD = 60000
TOSS_OPERATOR_GAS_OVERHEAD = 220000
```

### Fee Calculation

```typescript
// Calculate operator gas cost in ETH
const operatorGas = OPERATOR_GAS_OVERHEAD * gasPrice;

// Convert to token amount
const gasFeeInToken = (operatorGas * 1e18) / tokenPrice;

// Toss fee (2.5% by default)
const tossFee = (amount * tossFeeBPS) / 10000;
```

## Example Usage

```typescript
// 1. Deposit
const depositAmount = ethers.utils.parseEther("100");
const depositSig = await getPermitSignature(
  tokenContract,
  userAddress,
  gameAddress,
  depositAmount,
  Math.floor(Date.now() / 1000) + 3600
);

await operatorAPI.depositToken({
  user: userAddress,
  token: tokenAddress,
  tokenAmount: depositAmount,
  tokenPrice: currentTokenPrice,
  deadline: depositSig.deadline,
  v: depositSig.v,
  r: depositSig.r,
  s: depositSig.s,
});

// 2. Toss
const tossAmount = ethers.utils.parseEther("10");
const tossSig = await getTossSignature(
  gameContract,
  userAddress,
  tokenAddress,
  tossAmount,
  currentTokenPrice,
  true // betting on heads
);

await operatorAPI.tossCoin(tossSig);

// 3. Withdraw
const withdrawAmount = ethers.utils.parseEther("50");
const withdrawSig = await getWithdrawSignature(
  gameContract,
  userAddress,
  tokenAddress,
  withdrawAmount,
  currentTokenPrice
);

await operatorAPI.withdrawToken(withdrawSig);
```

## Events to Monitor

```typescript
// Result of toss
contract.on("CoinTossResult", (requestId, amountWon, tossResult, isWon) => {});

// Stats update
contract.on("StatsUpdated", (user, winCount, tossCount, prize) => {});

// Leaderboard changes
contract.on(
  "LeaderboardUpdated",
  (user, rank, winCount, tossCount, prize) => {}
);
```

## Error Handling

Common errors to handle:

- `InvalidSignature`: Signature verification failed
- `InsufficientBalance`: Not enough tokens
- `InsufficientFundForGasFee`: Amount too small to cover gas
- `UnsupportedToken`: Token not supported by game

## Setup

### 1. Initialize Provider and Signer

```typescript
// Using ethers v5
import { ethers } from "ethers";

// Check if MetaMask is installed
if (!window.ethereum) {
  throw new Error("Please install MetaMask!");
}

// Request MetaMask connection
async function connectWallet() {
  try {
    // Request account access
    await window.ethereum.request({ method: "eth_requestAccounts" });

    // Initialize provider and signer
    const provider = new ethers.providers.Web3Provider(window.ethereum);
    const signer = provider.getSigner();
    const userAddress = await signer.getAddress();

    // Listen for account changes
    window.ethereum.on("accountsChanged", (accounts: string[]) => {
      if (accounts.length === 0) {
        // Handle disconnection
        console.log("Please connect to MetaMask");
      } else {
        // Handle account change
        console.log("Account changed to:", accounts[0]);
      }
    });

    // Listen for chain changes
    window.ethereum.on("chainChanged", (chainId: string) => {
      // Handle chain change (usually by reloading the page)
      window.location.reload();
    });

    return { provider, signer, userAddress };
  } catch (error) {
    if (error.code === 4001) {
      throw new Error("Please connect to MetaMask");
    }
    throw error;
  }
}

// Or with private key (backend/testing)
const privateKey = process.env.PRIVATE_KEY;
const provider = new ethers.providers.JsonRpcProvider(RPC_URL);
const signer = new ethers.Wallet(privateKey, provider);
```

### 2. Contract Setup

```typescript
// Contract addresses (replace with your deployed addresses)
const GAME_ADDRESS = "0x...";
const TOKEN_ADDRESS = "0x...";

// Import ABIs
import GAME_ABI from "./abis/TossGame.json";
import TOKEN_ABI from "./abis/ERC20.json";

// Create contract instances
async function setupContracts(provider: ethers.providers.Provider) {
  const gameContract = new ethers.Contract(GAME_ADDRESS, GAME_ABI, provider);
  const tokenContract = new ethers.Contract(TOKEN_ADDRESS, TOKEN_ABI, provider);

  // Get chain ID
  const { chainId } = await provider.getNetwork();

  return { gameContract, tokenContract, chainId };
}
```

### 3. Domain and Types Setup

```typescript
// EIP712 Domain and Types
const setupEIP712 = (chainId: number, gameAddress: string) => {
  // Domain for TossGame
  const domain = {
    name: "TossGame",
    version: "1",
    chainId: chainId,
    verifyingContract: gameAddress,
  };

  // Types matching contract's type hashes
  const TYPES = {
    TossCoin: [
      { name: "user", type: "address" },
      { name: "token", type: "address" },
      { name: "tokenAmount", type: "uint256" },
      { name: "tokenPrice", type: "uint256" },
      { name: "nonce", type: "uint256" },
      { name: "deadline", type: "uint256" },
      { name: "tossResult", type: "bool" },
    ],
    Withdraw: [
      { name: "user", type: "address" },
      { name: "token", type: "address" },
      { name: "tokenAmount", type: "uint256" },
      { name: "tokenPrice", type: "uint256" },
      { name: "nonce", type: "uint256" },
      { name: "deadline", type: "uint256" },
    ],
  };

  return { domain, TYPES };
};
```

### 4. Signature Manager

```typescript
class SignatureManager {
  private signer: ethers.Signer;
  private domain: any;
  private types: any;
  private gameContract: ethers.Contract;

  constructor(
    signer: ethers.Signer,
    domain: any,
    types: any,
    gameContract: ethers.Contract
  ) {
    this.signer = signer;
    this.domain = domain;
    this.types = types;
    this.gameContract = gameContract;
  }

  async requestSignature(
    type: "TossCoin" | "Withdraw",
    value: any
  ): Promise<any> {
    try {
      // Add nonce and deadline if not present
      if (!value.nonce) {
        value.nonce = await this.gameContract.nonces(
          await this.signer.getAddress()
        );
      }
      if (!value.deadline) {
        value.deadline = Math.floor(Date.now() / 1000) + 3600;
      }

      // Request signature from MetaMask
      const signature = await this.signer._signTypedData(
        this.domain,
        { [type]: this.types[type] },
        value
      );

      return {
        ...value,
        ...ethers.utils.splitSignature(signature),
      };
    } catch (error) {
      if (error.code === 4001) {
        throw new Error("User rejected signature request");
      }
      throw error;
    }
  }
}
```

### 5. Complete Setup Example

```typescript
async function initializeTossGame() {
  try {
    // 1. Connect wallet
    const { provider, signer, userAddress } = await connectWallet();

    // 2. Setup contracts
    const { gameContract, tokenContract, chainId } = await setupContracts(
      provider
    );

    // 3. Setup EIP712
    const { domain, TYPES } = setupEIP712(chainId, gameContract.address);

    // 4. Create signature manager
    const signatureManager = new SignatureManager(
      signer,
      domain,
      TYPES,
      gameContract
    );

    return {
      provider,
      signer,
      userAddress,
      gameContract,
      tokenContract,
      signatureManager,
    };
  } catch (error) {
    console.error("Failed to initialize:", error);
    throw error;
  }
}

// Usage example
const game = await initializeTossGame();

// Request toss signature
const tossSig = await game.signatureManager.requestSignature("TossCoin", {
  user: game.userAddress,
  token: TOKEN_ADDRESS,
  tokenAmount: ethers.utils.parseEther("1"),
  tokenPrice: await getTokenPrice(TOKEN_ADDRESS),
  tossResult: true,
});

// Submit to operator
await operatorAPI.tossCoin(tossSig);
```

Note: signer.\_signTypedData should pop up a MetaMask prompt to sign the message.
