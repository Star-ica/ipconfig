# IPConfig — Deployment Instructions

## Prerequisites

- Node.js v18+
- Hardhat
- A BOT Chain RPC endpoint and deployer private key

---

## 1. Install dependencies

```bash
npm init -y
npm install --save-dev hardhat @nomicfoundation/hardhat-toolbox
npx hardhat init   # choose "Create a JavaScript project"
```

Copy `contracts/IPConfig.sol` into the `contracts/` directory.

---

## 2. Configure hardhat

Edit `hardhat.config.js`:

```js
require("@nomicfoundation/hardhat-toolbox");

module.exports = {
  solidity: {
    version: "0.8.20",
    settings: { optimizer: { enabled: true, runs: 200 } }
  },
  networks: {
    botchain: {
      url: "https://rpc.botchain.tg",        // BOT Chain RPC
      chainId: 6805,                          // confirm with BOT Chain docs
      accounts: [process.env.PRIVATE_KEY]
    }
  }
};
```

---

## 3. Write a deploy script

Create `scripts/deploy.js`:

```js
const { ethers } = require("hardhat");

async function main() {
  const [deployer] = await ethers.getSigners();
  console.log("Deploying with:", deployer.address);

  // Constructor args:
  // 1. USDT token address on BOT Chain
  // 2. Platform fee in basis points (e.g. 300 = 3%)
  // 3. Registration fee in wei (e.g. 0.01 BOT = 10000000000000000)
  const USDT_ADDRESS    = "0x...";   // fill in
  const PLATFORM_FEE    = 300;
  const REGISTRATION_FEE = ethers.parseEther("0.01");

  const IPConfig = await ethers.deployContract("IPConfig", [
    USDT_ADDRESS,
    PLATFORM_FEE,
    REGISTRATION_FEE
  ]);
  await IPConfig.waitForDeployment();

  const addr = await IPConfig.getAddress();
  console.log("IPConfig deployed to:", addr);
}

main().catch(err => { console.error(err); process.exit(1); });
```

---

## 4. Set environment variable

```bash
export PRIVATE_KEY="0x..."
```

---

## 5. Deploy

```bash
npx hardhat run scripts/deploy.js --network botchain
```

---

## 6. Update the frontend

Open `frontend/index.html` and update the two constants near the top of the `<script>` section:

```js
const CONTRACT_ADDRESS = "0x<IPConfig deployed address>";
const USDT_ADDRESS     = "0x<USDT token address on BOT Chain>";
```

---

## 7. Run tests

```bash
# Also create tests/ERC20Mock.sol (a minimal mintable ERC20) for the test suite
npx hardhat test
```

---

## ERC20Mock (required for tests)

Create `contracts/ERC20Mock.sol`:

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
contract ERC20Mock is ERC20 {
    uint8 private _dec;
    constructor(string memory name, string memory symbol, uint8 dec) ERC20(name, symbol) {
        _dec = dec;
    }
    function decimals() public view override returns (uint8) { return _dec; }
    function mint(address to, uint256 amount) external { _mint(to, amount); }
}
```

Install OpenZeppelin:

```bash
npm install @openzeppelin/contracts
```

---

## 8. Serve the frontend

The frontend is a single static HTML file with no build step required.

```bash
# Any static server works, e.g.:
npx serve frontend/
# or simply open frontend/index.html in a browser
```

---

## Security checklist before mainnet

- [ ] Audit `IPConfig.sol` with Slither or a professional firm
- [ ] Confirm BOT Chain chainId to prevent replay attacks
- [ ] Verify USDT token address is the official one on BOT Chain
- [ ] Test registration fee and platform fee values with the team
- [ ] Set `admin` to a multisig after initial deployment
- [ ] Review `withdrawAdminFees` access control
