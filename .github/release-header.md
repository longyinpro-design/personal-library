## 下载与安装

1. 下载本页附件中的 `PersonalLibrary-*-macos-arm64.dmg` 与对应的 `.sha256` 文件。
2. 校验下载（两个文件放在同一目录）：

   ```sh
   shasum -a 256 -c PersonalLibrary-*.dmg.sha256
   ```

3. 打开 DMG，将「个人资料库.app」拖入 Applications 文件夹。
4. 首次启动如提示「无法验证开发者」，请右键点击 App 选择「打开」，或执行：

   ```sh
   xattr -dr com.apple.quarantine "/Applications/个人资料库.app"
   ```

## 说明

- 系统要求：macOS 14 或更高版本，Apple 芯片（arm64）。
- 构建使用 ad-hoc 签名，未经过 Apple 公证；如遇安全提示，请按上面的步骤手动允许。
- 资料全部保存在本机，不涉及账户或云服务。
