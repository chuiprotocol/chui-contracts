# chui-contracts —— Chui Protocol 智能合約（多鏈）

```
contracts/
├── evm/      EVM 系合約（尚未開始）
├── solana/   Solana 合約（尚未開始）
└── sui/      Sui Move 合約（尚未有程式碼；應用層假定介面見 chui-app 的 DECISIONS.md D1）
```

注意：本 repo 在 2026-09-01 建立目錄骨架時**尚無任何合約程式碼**——
chui-app（應用層）目前是以可設定的假定介面對接，等 `contracts/sui/`
有實作並部署後，於 `deployments/testnet.json` 提供 package ID 與
shared object ID，應用層只需改環境變數即可接上。
