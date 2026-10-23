import XCTest

@testable import ClashBar

final class ConfigOverrideMergerTests: XCTestCase {
    private let sourceConfig = """
    port: 7890
    ipv6: true
    external-controller: 127.0.0.1:9090
    rules:
      - MATCH,DIRECT
      - GEOIP,CN,DIRECT
    proxies: []
    """

    func testPrependsRulesBeforeExistingOnesAndOverridesScalars() {
        let override = """
        # 本文件是覆写示例
        ipv6: false

        +rules:
          - "DOMAIN-SUFFIX,baidu.com,DIRECT"
          - "IP-CIDR,192.168.1.0/24,DIRECT"
        """

        let outcome = ConfigOverrideMerger.mergedText(sourceText: sourceConfig, overrideText: override)

        XCTAssertNotNil(outcome)
        XCTAssertEqual(outcome?.appliedKeys, ["ipv6", "+rules"])
        let expected = """
        port: 7890
        ipv6: false
        external-controller: 127.0.0.1:9090
        rules:
          - "DOMAIN-SUFFIX,baidu.com,DIRECT"
          - "IP-CIDR,192.168.1.0/24,DIRECT"
          - MATCH,DIRECT
          - GEOIP,CN,DIRECT
        proxies: []

        """
        XCTAssertEqual(outcome?.text, expected)
    }

    func testAppendsRulesWhenSourceHasNoRulesKey() {
        let source = """
        port: 7890
        proxies: []
        """
        let override = """
        +rules:
          - "DOMAIN-SUFFIX,apple.com,DIRECT"
        """

        let outcome = ConfigOverrideMerger.mergedText(sourceText: source, overrideText: override)

        let expected = """
        port: 7890
        proxies: []

        rules:
          - "DOMAIN-SUFFIX,apple.com,DIRECT"

        """
        XCTAssertEqual(outcome?.text, expected)
        XCTAssertEqual(outcome?.appliedKeys, ["+rules"])
    }

    func testConvertsEmptyFlowListToBlock() {
        let source = """
        rules: []
        port: 7890
        """
        let override = """
        +rules:
          - "DOMAIN-SUFFIX,icloud.com,DIRECT"
        """

        let outcome = ConfigOverrideMerger.mergedText(sourceText: source, overrideText: override)

        let expected = """
        rules:
          - "DOMAIN-SUFFIX,icloud.com,DIRECT"
        port: 7890

        """
        XCTAssertEqual(outcome?.text, expected)
    }

    func testReindentsPrependedItemsToSourceIndentation() {
        let source = """
        rules:
            - MATCH,DIRECT
        """
        let override = """
        +rules:
          - "DOMAIN-SUFFIX,swift.org,DIRECT"
        """

        let outcome = ConfigOverrideMerger.mergedText(sourceText: source, overrideText: override)

        let expected = """
        rules:
            - "DOMAIN-SUFFIX,swift.org,DIRECT"
            - MATCH,DIRECT

        """
        XCTAssertEqual(outcome?.text, expected)
    }

    func testReplacesTopLevelBlock() {
        let source = """
        dns:
          enable: true
          nameserver:
            - 8.8.8.8
        rules:
          - MATCH,DIRECT
        """
        let override = """
        dns:
          enable: false
          enhanced-mode: fake-ip
        """

        let outcome = ConfigOverrideMerger.mergedText(sourceText: source, overrideText: override)

        let expected = """
        dns:
          enable: false
          enhanced-mode: fake-ip
        rules:
          - MATCH,DIRECT

        """
        XCTAssertEqual(outcome?.text, expected)
        XCTAssertEqual(outcome?.appliedKeys, ["dns"])
    }

    func testAppendsScalarWhenSourceKeyMissing() {
        let source = """
        port: 7890
        proxies: []
        """
        let override = "ipv6: false"

        let outcome = ConfigOverrideMerger.mergedText(sourceText: source, overrideText: override)

        XCTAssertTrue(outcome?.text.hasSuffix("\nipv6: false\n") == true)
        XCTAssertEqual(outcome?.appliedKeys, ["ipv6"])
    }

    func testReturnsNilForCommentOnlyOverride() {
        let override = """
        # 只有注释
        # ipv6: false
        """

        XCTAssertNil(ConfigOverrideMerger.mergedText(sourceText: sourceConfig, overrideText: override))
    }

    func testReturnsNilForEmptyOverride() {
        XCTAssertNil(ConfigOverrideMerger.mergedText(sourceText: sourceConfig, overrideText: ""))
        XCTAssertNil(ConfigOverrideMerger.mergedText(sourceText: sourceConfig, overrideText: "\n\n"))
    }

    func testBareKeyWithoutValueIsNoOp() {
        let override = "rules:"

        XCTAssertNil(ConfigOverrideMerger.mergedText(sourceText: sourceConfig, overrideText: override))
    }

    func testPlusKeyWithInlineValueIsNoOp() {
        let override = "+rules: []"

        XCTAssertNil(ConfigOverrideMerger.mergedText(sourceText: sourceConfig, overrideText: override))
    }

    func testHandlesCRLFLineEndings() {
        let override = "ipv6: false\r\n+rules:\r\n  - \"DOMAIN-SUFFIX,jd.com,DIRECT\"\r\n"

        let outcome = ConfigOverrideMerger.mergedText(sourceText: sourceConfig, overrideText: override)

        XCTAssertEqual(outcome?.appliedKeys, ["ipv6", "+rules"])
        XCTAssertFalse(outcome?.text.contains("\r") == true)
    }

    func testPreservesInlineCommentsOnOverrideItems() {
        let override = """
        +rules:
          # Apple 直连
          - "DOMAIN-SUFFIX,apple.com,DIRECT"   # idmsa
        """

        let outcome = ConfigOverrideMerger.mergedText(sourceText: sourceConfig, overrideText: override)

        let expected = """
        port: 7890
        ipv6: true
        external-controller: 127.0.0.1:9090
        rules:
          # Apple 直连
          - "DOMAIN-SUFFIX,apple.com,DIRECT"   # idmsa
          - MATCH,DIRECT
          - GEOIP,CN,DIRECT
        proxies: []

        """
        XCTAssertEqual(outcome?.text, expected)
    }

    func testMergesDesktopStyleOverrideFile() {
        // Mirrors the real-world override file this feature was built for.
        let override = """
        # 添加直连规则示例

        # 本机无 IPv6 出口,关闭内核 IPv6 总开关
        ipv6: false

        +rules:
          - "DOMAIN-SUFFIX,baidu.com,DIRECT"
          - "DOMAIN-SUFFIX,tencent.com,DIRECT"
          - "IP-CIDR,8.137.105.184/32,DIRECT"
          - "IP-CIDR,10.10.10.200/21,DIRECT"
          # ===== Apple 全家桶 =====
          - "DOMAIN-SUFFIX,apple.com,DIRECT"
          - "DOMAIN-SUFFIX,icloud.com,DIRECT"
        """

        let outcome = ConfigOverrideMerger.mergedText(sourceText: sourceConfig, overrideText: override)

        XCTAssertNotNil(outcome)
        let lines = outcome?.text.components(separatedBy: "\n") ?? []
        let firstRuleIndex = lines.firstIndex(of: "rules:")
        let baiduIndex = lines.firstIndex(of: "  - \"DOMAIN-SUFFIX,baidu.com,DIRECT\"")
        let matchIndex = lines.firstIndex(of: "  - MATCH,DIRECT")
        XCTAssertNotNil(firstRuleIndex)
        XCTAssertNotNil(baiduIndex)
        XCTAssertNotNil(matchIndex)
        if let baiduIndex, let matchIndex {
            XCTAssertLessThan(baiduIndex, matchIndex)
        }
        XCTAssertTrue(outcome?.text.contains("ipv6: false") == true)
        XCTAssertFalse(outcome?.text.contains("ipv6: true") == true)
    }

    func testReservedFileNameDetection() {
        XCTAssertTrue(ConfigOverrideMerger.isReservedFileName("override.yaml"))
        XCTAssertTrue(ConfigOverrideMerger.isReservedFileName("override.yml"))
        XCTAssertTrue(ConfigOverrideMerger.isReservedFileName("Override.YAML"))
        XCTAssertFalse(ConfigOverrideMerger.isReservedFileName("Override2.yaml"))
        XCTAssertFalse(ConfigOverrideMerger.isReservedFileName("my-override.yaml"))
    }
}
