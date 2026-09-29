# app 编译走 SPM（Package.swift，Xcode 26.6 起本机 SPM 已修复）；
# Makefile 负责：打包 .app + 图标 + 签名 + 测试（自定义 runner 非 XCTest，swiftc 直编）+ 冒烟工具
APP_NAME = Parrotlet
APP_DIR = build/$(APP_NAME).app
BIN_DIR = build/bin

# Sparkle 只在 SPM app 构建里链接（Package.swift -D HAS_SPARKLE）；
# swiftc 路径（typecheck/测试/冒烟）无 Sparkle 模块可导入，该文件由 swift build 把关
SOURCES := $(filter-out %/SparkleUpdateController.swift,$(shell find Sources -name '*.swift' | sort))

# 签名身份：维护机有自签证书 "Mellivora Local Dev"（Keychain 免弹框 + Sparkle 新旧包
# 同身份校验都靠它）；外部贡献者的机器没有该证书 → 自动回退 ad-hoc(--sign -)，构建照常可用。
# 也可显式覆盖：make app CODESIGN_IDENTITY=-
CODESIGN_IDENTITY ?= $(shell security find-identity -v -p codesigning 2>/dev/null | \
	grep -q "Mellivora Local Dev" && echo "Mellivora Local Dev" || echo "-")
# 测试二进制不能带 app 的 @main 入口
NON_APP_SOURCES := $(filter-out %/ParrotletApp.swift,$(SOURCES))
TEST_SOURCES := $(shell find Tests -name '*.swift' | sort)
SMOKE_SOURCES := Smoke/llmSmoke.swift

SWIFT_COMMON_FLAGS = -parse-as-library -strict-concurrency=complete -target arm64-apple-macos15.0

.PHONY: build app run test swift6-typecheck smoke-compile llm-smoke clean icon

# Swift 6 language-mode gate: app sources and test binary sources must both typecheck.
swift6-typecheck:
	swiftc $(SWIFT_COMMON_FLAGS) -swift-version 6 -typecheck $(SOURCES)
	swiftc $(SWIFT_COMMON_FLAGS) -swift-version 6 -typecheck $(NON_APP_SOURCES) $(TEST_SOURCES)

# 只编译真实网络冒烟工具，不执行请求；PR/CI 必跑。
smoke-compile: $(NON_APP_SOURCES) $(SMOKE_SOURCES)
	mkdir -p $(BIN_DIR)
	swiftc $(SWIFT_COMMON_FLAGS) -Onone \
		-o $(BIN_DIR)/llmSmoke $(NON_APP_SOURCES) $(SMOKE_SOURCES)

# 重新生成应用图标（M 鹦鹉，绘制逻辑在脚本里，改完跑这个）
icon:
	swift assets/icon/make-icon.swift

# SPM release 构建（-O + WMO），产物归置到 build/bin 供打包
build:
	mkdir -p $(BIN_DIR)
	swift build -c release
	cp .build/release/$(APP_NAME) $(BIN_DIR)/$(APP_NAME)

# 组装 .app 并签名（本地构建无 quarantine，Gatekeeper 不拦）
app: build
	rm -rf $(APP_DIR)
	mkdir -p $(APP_DIR)/Contents/MacOS $(APP_DIR)/Contents/Resources
	cp $(BIN_DIR)/$(APP_NAME) $(APP_DIR)/Contents/MacOS/
	cp Info.plist $(APP_DIR)/Contents/Info.plist
	# 随包字体（Inter，ATSApplicationFontsPath=fonts）：换机/分发不依赖系统安装
	mkdir -p $(APP_DIR)/Contents/Resources/fonts
	cp assets/fonts/* $(APP_DIR)/Contents/Resources/fonts/
	# 应用图标（CFBundleIconFile=AppIcon）：改图后先 make icon 重新生成
	cp assets/icon/AppIcon.icns $(APP_DIR)/Contents/Resources/
	# 菜单栏 template 图标（M 鹦鹉剪影，NSImage(named:) 按名加载）
	cp assets/icon/menubar.png assets/icon/menubar@2x.png $(APP_DIR)/Contents/Resources/
	# provider 官方品牌图标（设置页模型列表用，NSImage(named:) 平铺按名加载）
	cp assets/providers/*.png $(APP_DIR)/Contents/Resources/
	# 内嵌 Sparkle.framework（SPM 不给可执行产物拷框架）+ 补 rpath 指向 Contents/Frameworks。
	# 路径在 recipe 里现算：Makefile 解析期 .build/artifacts 可能还不存在（干净克隆首跑），
	# 必须等 build 步骤把 SPM artifact 拉下来之后再 find
	mkdir -p $(APP_DIR)/Contents/Frameworks
	SPARKLE_FW=$$(find .build/artifacts -type d -name Sparkle.framework -path '*macos*' | head -1); \
	test -n "$$SPARKLE_FW" || { echo "❌ 找不到 Sparkle.framework（.build/artifacts 为空？）"; exit 1; }; \
	cp -R "$$SPARKLE_FW" $(APP_DIR)/Contents/Frameworks/
	install_name_tool -add_rpath @executable_path/../Frameworks $(APP_DIR)/Contents/MacOS/$(APP_NAME) 2>/dev/null || true
	plutil -lint $(APP_DIR)/Contents/Info.plist
	# 嵌套代码（Sparkle.framework 及其 XPC）先签、与外层同身份，Sparkle 更新校验才认。
	# 维护机 = "Mellivora Local Dev" 稳定证书（授权一次终身有效）；外部贡献者自动回退 ad-hoc
	codesign --force --sign "$(CODESIGN_IDENTITY)" $(APP_DIR)/Contents/Frameworks/Sparkle.framework
	codesign --force --sign "$(CODESIGN_IDENTITY)" $(APP_DIR)
	codesign --verify $(APP_DIR)
	@echo "✅ $(APP_DIR) 已就绪"

# 验收一律走 make run（无 Info.plist 的裸二进制没有 LSUIElement 等行为）
run: app
	open $(APP_DIR)

test: $(TEST_SOURCES) $(NON_APP_SOURCES)
	mkdir -p $(BIN_DIR)
	swiftc $(SWIFT_COMMON_FLAGS) -Onone \
		-o $(BIN_DIR)/ParrotletTests $(NON_APP_SOURCES) $(TEST_SOURCES)
	$(BIN_DIR)/ParrotletTests

# LLM 真实冒烟（target 名避开 Smoke/ 目录的大小写冲突）：读 App Support 的 config.json，向 activeProvider 发流式请求
# API key 可用环境变量提供，如：DEEPSEEK_API_KEY=sk-xxx make llm-smoke
# ARGS=chat 跑聊天端到端（多轮 + 总结）
llm-smoke: $(NON_APP_SOURCES) $(SMOKE_SOURCES)
	mkdir -p $(BIN_DIR)
	swiftc $(SWIFT_COMMON_FLAGS) -Onone \
		-o $(BIN_DIR)/llmSmoke $(NON_APP_SOURCES) $(SMOKE_SOURCES)
	$(BIN_DIR)/llmSmoke $(ARGS)

clean:
	rm -rf $(BIN_DIR) $(APP_DIR)
