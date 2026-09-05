# chui（Sui Move 合約套件）

三個模組：`vault`（預授權代付，主流程）、`pay`（一次性直付）、
`log_policy`（Seal 解密授權）。完整設計、威脅模型與 abort codes
見 [repo 根 README](../../README.md)；各模組檔頭註解記載「為什麼這樣做」。

```bash
sui move test    # 17 案例
./deploy.sh      # Testnet 部署＋印出 CHUI_PACKAGE_ID
```

Move.toml 刻意**不明寫** Sui framework 相依——sui CLI（1.45+）會自動注入
與自身相符的框架版本；明寫 git rev 會與本機 CLI 的 VM 版本錯配，
造成 MISSING_DEPENDENCY／UNEXPECTED_VERIFIER_ERROR（踩過的雷）。
