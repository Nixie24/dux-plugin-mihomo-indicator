import QtQuick
import Quickshell
import Quickshell.Io
import qs.Common
import qs.Services
import qs.Widgets
import qs.DCommon.Widgets
import qs.Modules.Plugins
import "MihomoApi.js" as Api

PluginComponent {
    id: root

    pluginId: "mihomoIndicator"
    pluginService: PluginService

    readonly property string pluginKey: "mihomoIndicator"
    readonly property string defaultConfigPath: "/etc/mihomo/config.yaml"
    // Proc debouncers are global, so each widget instance needs its own prefix.
    readonly property string procPrefix: pluginKey + "." + (widgetInstanceId !== "" ? widgetInstanceId : Math.random().toString(36).slice(2, 10))

    // ---------- settings ----------

    readonly property string configPath: {
        const value = pluginData?.configPath;
        return typeof value === "string" && value.trim() !== "" ? value.trim() : defaultConfigPath;
    }

    readonly property string apiOverride: {
        const value = pluginData?.apiOverride;
        return typeof value === "string" ? value.trim() : "";
    }

    readonly property string secretOverride: {
        const value = pluginData?.secretOverride;
        return typeof value === "string" ? value.trim() : "";
    }

    readonly property int refreshInterval: {
        const value = Number(pluginData?.refreshInterval);
        if (!isFinite(value) || value < 1)
            return 2;
        return Math.min(60, Math.round(value));
    }

    readonly property bool showSpeed: pluginData?.showSpeed !== false
    readonly property bool showProxyName: pluginData?.showProxyName === true
    readonly property bool hideIcon: pluginData?.hideIcon === true

    readonly property string preferredGroup: {
        const value = pluginData?.displayGroup;
        return typeof value === "string" ? value.trim() : "";
    }

    readonly property string testUrl: {
        const value = pluginData?.testUrl;
        return typeof value === "string" && value.trim() !== "" ? value.trim() : "https://www.gstatic.com/generate_204";
    }

    readonly property real iconScale: {
        const raw = pluginData?.iconScale;
        if (raw === undefined || raw === null || raw === "")
            return 1.0;
        const percent = Number(raw);
        if (!isFinite(percent))
            return 1.0;
        return Math.max(0.5, Math.min(2.0, percent / 100));
    }

    readonly property string groupVisibility: {
        const value = pluginData?.groupVisibility;
        return value === "hide" || value === "only" ? value : "all";
    }

    readonly property var groupFilter: {
        const raw = pluginData?.groupFilter;
        if (Array.isArray(raw))
            return raw;
        if (typeof raw === "string" && raw.trim() !== "") {
            try {
                const parsed = JSON.parse(raw);
                if (Array.isArray(parsed))
                    return parsed;
            } catch (error) {
                // Fall through to the comma separated form.
            }
            return raw.split(",").map(item => item.trim()).filter(item => item !== "");
        }
        return [];
    }

    // ---------- config / endpoint ----------

    property string controllerHost: "127.0.0.1"
    property int controllerPort: 9090
    property string configSecret: ""
    property string unixSocket: ""
    property string configError: ""
    property bool configReady: false
    property var configGroupOrder: []

    readonly property string apiSecret: secretOverride !== "" ? secretOverride : configSecret

    readonly property string apiBase: {
        if (apiOverride !== "")
            return Api.normalizeBase(apiOverride);
        if (unixSocket !== "")
            return "http://localhost";
        const host = controllerHost.indexOf(":") >= 0 ? "[" + controllerHost + "]" : controllerHost;
        return "http://" + host + ":" + controllerPort;
    }

    // ---------- mihomo state ----------

    property bool apiReachable: false
    property string lastError: ""
    property string mihomoVersion: ""
    property string mode: ""
    property bool tunEnabled: false
    property int upSpeed: 0
    property int downSpeed: 0
    property int upTotal: 0
    property int downTotal: 0
    property int connectionCount: 0
    property var proxyGroups: []
    property var nodeDelays: ({})
    // /group/{name}/delay results are not written to node history, so keep
    // recent manual test results around until the next test.
    property var testedDelays: ({})
    property var proxyInfo: ({})
    property string groupsSignature: ""
    property string selectedGroupName: ""
    property bool testing: false
    property int tickCount: 0
    property bool stoppingTraffic: false

    property var inflight: ({})

    readonly property var visibleGroups: {
        const groups = proxyGroups;
        if (!groups || groups.length === 0)
            return [];
        if (groupVisibility === "all")
            return groups;
        const selected = groupFilter;
        if (groupVisibility === "only") {
            if (selected.length === 0)
                return groups;
            return groups.filter(item => selected.indexOf(item.name) >= 0);
        }
        return groups.filter(item => selected.indexOf(item.name) < 0);
    }

    readonly property var activeGroup: {
        const groups = visibleGroups;
        if (!groups || groups.length === 0)
            return null;
        const wanted = selectedGroupName !== "" ? selectedGroupName : preferredGroup;
        let group = null;
        if (wanted !== "")
            group = groups.find(item => item.name === wanted) || null;
        if (!group)
            group = groups.find(item => item.name === "Final") || null;
        if (!group)
            group = groups.find(item => item.type === "Selector") || null;
        if (!group)
            group = groups[0];
        return group;
    }

    readonly property string statusLine: {
        if (!apiReachable)
            return I18n.trFor("mihomoIndicator", "Not connected");
        const parts = [];
        if (mihomoVersion !== "")
            parts.push(mihomoVersion);
        parts.push(modeLabel(mode));
        if (tunEnabled)
            parts.push(I18n.trFor("mihomoIndicator", "TUN"));
        return parts.join(" · ");
    }

    readonly property string proxyText: {
        if (!apiReachable || !showProxyName || !activeGroup)
            return "";
        return activeGroup.now || "";
    }

    readonly property color stateColor: apiReachable ? Theme.primary : Theme.surfaceVariantText
    readonly property int glyphSize: Theme.barIconSize(barThickness, undefined, barConfig?.maximizeWidgetIcons, (barConfig?.iconScale ?? 1.0) * iconScale)
    readonly property int barTextSize: Theme.barTextSize(barThickness, barConfig?.fontScale, barConfig?.maximizeWidgetText)

    // ---------- helpers ----------

    function modeLabel(value) {
        switch (value) {
        case "global":
            return I18n.trFor("mihomoIndicator", "Global");
        case "direct":
            return I18n.trFor("mihomoIndicator", "Direct");
        case "rule":
            return I18n.trFor("mihomoIndicator", "Rule");
        }
        return value || I18n.trFor("mihomoIndicator", "Unknown");
    }

    function formatRate(bytesPerSec) {
        return Api.formatRate(bytesPerSec, 1);
    }

    function compactRate(bytesPerSec) {
        if (!isFinite(bytesPerSec) || bytesPerSec <= 0)
            return "0";
        if (bytesPerSec < 1024)
            return String(Math.round(bytesPerSec));
        if (bytesPerSec < 1024 * 1024)
            return Math.round(bytesPerSec / 1024) + "K";
        if (bytesPerSec < 1024 * 1024 * 1024)
            return (bytesPerSec / (1024 * 1024)).toFixed(1) + "M";
        return (bytesPerSec / (1024 * 1024 * 1024)).toFixed(1) + "G";
    }

    function formatBytes(bytes) {
        return Api.formatBytes(bytes);
    }

    function applyConfigText(text, readError) {
        controllerHost = "127.0.0.1";
        controllerPort = 9090;
        configSecret = "";
        unixSocket = "";
        configGroupOrder = [];
        configError = readError || "";

        if (!text) {
            if (configError === "")
                configError = I18n.trFor("mihomoIndicator", "Config file is empty");
            return;
        }

        const config = Api.parseConfig(text);
        configSecret = config.secret;
        unixSocket = config.unixSocket;
        configGroupOrder = config.groupOrder || [];

        const endpoint = Api.endpointFromController(config.controller);
        if (endpoint) {
            controllerHost = endpoint.host;
            controllerPort = endpoint.port;
            configError = "";
            return;
        }
        if (config.unixSocket !== "") {
            configError = "";
            return;
        }
        configError = I18n.trFor("mihomoIndicator", "external-controller not found in config");
    }

    function reloadConfig() {
        configReady = false;
        const path = configPath.startsWith("~") ? (Quickshell.env("HOME") || "") + configPath.slice(1) : configPath;
        Proc.runCommand(procPrefix + ".config", ["cat", path], (stdout, exitCode) => {
            if (exitCode !== 0) {
                applyConfigText("", I18n.trFor("mihomoIndicator", "Cannot read the config file"));
            } else {
                applyConfigText(stdout, "");
            }
            configReady = true;
            refreshAll();
        }, 0, 4000, root);
    }

    function parseResponse(stdout, exitCode) {
        return Api.parseResponse(stdout, exitCode);
    }

    function curlCommand(path, method, body, maxTime) {
        return Api.curlArgs(apiBase, apiSecret, apiOverride === "" ? unixSocket : "", path, method, body, maxTime);
    }

    function trafficCommand() {
        return Api.trafficArgs(apiBase, apiSecret, apiOverride === "" ? unixSocket : "");
    }

    function updateTrafficStream() {
        const shouldRun = surfaceLive && configReady;
        if (shouldRun && !trafficProcess.running) {
            stoppingTraffic = false;
            trafficProcess.running = true;
        } else if (!shouldRun && trafficProcess.running) {
            stoppingTraffic = true;
            trafficProcess.running = false;
        }
    }

    function restartTrafficStream() {
        if (trafficProcess.running) {
            stoppingTraffic = true;
            trafficProcess.running = false;
        }
        Qt.callLater(root.updateTrafficStream);
    }

    function request(key, path, callback, options) {
        if (inflight[key])
            return false;
        inflight[key] = true;
        const opts = options || {};
        const command = curlCommand(path, opts.method || "GET", opts.body, opts.maxTime || 3);
        Proc.runCommand(procPrefix + "." + key, command, (stdout, exitCode) => {
            inflight[key] = false;
            callback(parseResponse(stdout, exitCode));
        }, 0, opts.timeoutMs || 5000, root);
        return true;
    }

    function markOk() {
        apiReachable = true;
        lastError = "";
    }

    function markFailure(result) {
        apiReachable = false;
        if (result.code === 401 || result.code === 403)
            lastError = I18n.trFor("mihomoIndicator", "The API secret was rejected");
        else if (result.code === 0 || result.exit !== 0)
            lastError = I18n.trFor("mihomoIndicator", "Cannot reach the mihomo API");
        else
            lastError = I18n.trFor("mihomoIndicator", "Mihomo API error %1").arg(result.code);
    }

    function refreshVersion() {
        request("version", "/version", result => {
            if (!result.ok) {
                markFailure(result);
                return;
            }
            try {
                const data = JSON.parse(result.body);
                mihomoVersion = data.version || "";
                markOk();
            } catch (error) {
                markFailure(result);
            }
        });
    }

    function refreshConfigs() {
        request("configs", "/configs", result => {
            if (!result.ok) {
                markFailure(result);
                return;
            }
            try {
                const data = JSON.parse(result.body);
                mode = data.mode || mode;
                tunEnabled = data.tun?.enable === true;
                markOk();
            } catch (error) {
                markFailure(result);
            }
        });
    }

    function applyTrafficLine(line) {
        const text = String(line || "").trim();
        if (text === "")
            return;
        try {
            const data = JSON.parse(text);
            upSpeed = Number(data.up) || 0;
            downSpeed = Number(data.down) || 0;
            upTotal = Number(data.upTotal) || 0;
            downTotal = Number(data.downTotal) || 0;
            markOk();
        } catch (error) {
            // A partial line can arrive while the stream is torn down.
        }
    }

    function refreshConnections() {
        request("connections", "/connections", result => {
            if (!result.ok)
                return;
            try {
                const data = JSON.parse(result.body);
                connectionCount = Array.isArray(data.connections) ? data.connections.length : 0;
                markOk();
            } catch (error) {
                // Ignore a malformed payload; the count is informational only.
            }
        });
    }

    function refreshProxies() {
        request("proxies", "/proxies", result => {
            if (!result.ok) {
                markFailure(result);
                return;
            }
            try {
                const parsed = Api.parseProxies(result.body);
                const groups = parsed.groups;
                const delays = parsed.delays;
                const info = parsed.info;
                if (configGroupOrder.length > 0) {
                    const rank = {};
                    for (let i = 0; i < configGroupOrder.length; i++)
                        rank[configGroupOrder[i]] = i;
                    const serverIndex = {};
                    groups.forEach((group, index) => serverIndex[group.name] = index);
                    groups.sort((a, b) => {
                        const ra = rank[a.name];
                        const rb = rank[b.name];
                        const va = ra !== undefined ? ra : 100000 + serverIndex[a.name];
                        const vb = rb !== undefined ? rb : 100000 + serverIndex[b.name];
                        return va - vb;
                    });
                }
                // Replacing the group array resets open dropdowns, so only do it
                // when the group list itself changed.
                const signature = groups.map(item => item.name + "|" + item.type + "|" + item.now + "|" + item.nodes.length).join("\n");
                if (signature !== groupsSignature) {
                    groupsSignature = signature;
                    proxyGroups = groups;
                }
                const now = Date.now();
                const merged = Object.assign({}, delays);
                for (const name in testedDelays) {
                    const entry = testedDelays[name];
                    if (entry && now - entry.time < 120000 && !(merged[name] >= 0))
                        merged[name] = entry.delay;
                }
                nodeDelays = merged;
                proxyInfo = info;
                markOk();
            } catch (error) {
                markFailure(result);
            }
        });
    }

    function refreshAll() {
        refreshVersion();
        refreshConfigs();
        refreshProxies();
        if (interactionActive)
            refreshConnections();
    }

    function tick() {
        if (!configReady)
            return;
        tickCount++;
        if (interactionActive) {
            refreshVersion();
            refreshConfigs();
            refreshProxies();
            refreshConnections();
        } else if (tickCount % 5 === 0) {
            refreshVersion();
            refreshConfigs();
            refreshProxies();
        }
    }

    function nodeDelay(name) {
        const delay = nodeDelays[name];
        return typeof delay === "number" ? delay : -1;
    }

    function delayText(name) {
        const delay = nodeDelay(name);
        if (delay < 0)
            return "—";
        if (delay === 0)
            return I18n.trFor("mihomoIndicator", "Timeout");
        return I18n.trFor("mihomoIndicator", "%1 ms").arg(delay);
    }

    function delayColor(name) {
        const delay = nodeDelay(name);
        if (delay < 0)
            return Theme.surfaceVariantText;
        if (delay === 0)
            return Theme.error;
        if (delay < 300)
            return Theme.primary;
        if (delay < 700)
            return Theme.tertiary;
        return Theme.error;
    }

    function selectNode(name, groupName) {
        const group = groupName ? proxyGroups.find(item => item.name === groupName) : activeGroup;
        if (!group || group.type !== "Selector" || name === group.now)
            return;
        request("select", "/proxies/" + encodeURIComponent(group.name), result => {
            if (!result.ok) {
                markFailure(result);
                return;
            }
            proxyGroups = proxyGroups.map(item => item.name === group.name ? Object.assign({}, item, { now: name }) : item);
            markOk();
            refreshProxies();
        }, {
            method: "PUT",
            body: JSON.stringify({ name: name }),
            timeoutMs: 8000
        });
    }

    function selectGroup(name) {
        selectedGroupName = name;
        if (pluginService)
            pluginService.savePluginData(pluginId, "displayGroup", name);
    }

    function setMode(newMode) {
        if (!apiReachable || newMode === mode)
            return;
        request("mode", "/configs", result => {
            if (!result.ok) {
                markFailure(result);
                return;
            }
            mode = newMode;
            markOk();
        }, {
            method: "PATCH",
            body: JSON.stringify({ mode: newMode }),
            timeoutMs: 8000
        });
    }

    function testGroup(groupName) {
        const group = groupName ? proxyGroups.find(item => item.name === groupName) : activeGroup;
        if (!group || testing)
            return;
        testing = true;
        const path = "/group/" + encodeURIComponent(group.name) + "/delay?url=" + encodeURIComponent(testUrl) + "&timeout=3000";
        request("delay", path, result => {
            testing = false;
            if (!result.ok) {
                markFailure(result);
                return;
            }
            try {
                const map = JSON.parse(result.body);
                const merged = Object.assign({}, nodeDelays);
                const tested = Object.assign({}, testedDelays);
                const now = Date.now();
                for (const name in map) {
                    if (map[name] && typeof map[name].delay === "number") {
                        merged[name] = map[name].delay;
                        tested[name] = { delay: map[name].delay, time: now };
                    }
                }
                testedDelays = tested;
                nodeDelays = merged;
                markOk();
            } catch (error) {
                markFailure(result);
            }
        }, {
            maxTime: 10,
            timeoutMs: 15000
        });
    }

    function refreshNow() {
        reloadConfig();
    }

    // ---------- lifecycle ----------

    Connections {
        target: SettingsData
        function onPluginSettingsChanged() {
            root.loadPluginData();
        }
    }

    Component.onCompleted: reloadConfig()

    onConfigPathChanged: Qt.callLater(root.reloadConfig)
    onApiOverrideChanged: Qt.callLater(root.refreshAll)
    onSecretOverrideChanged: Qt.callLater(root.refreshAll)
    onPreferredGroupChanged: {
        if (selectedGroupName !== preferredGroup)
            selectedGroupName = "";
    }
    onConfigReadyChanged: updateTrafficStream()
    onSurfaceLiveChanged: updateTrafficStream()
    onApiBaseChanged: restartTrafficStream()
    onApiSecretChanged: restartTrafficStream()
    onInteractionActiveChanged: {
        if (interactionActive)
            refreshAll();
    }

    Timer {
        interval: Math.max(1, root.refreshInterval) * 1000
        running: root.surfaceLive && root.configReady
        repeat: true
        triggeredOnStart: true
        onTriggered: root.tick()
    }

    // /traffic is a streaming endpoint: one JSON object per second, and the
    // connection stays open. A single long-lived curl is cheaper than polling.
    Process {
        id: trafficProcess
        running: false
        command: root.trafficCommand()

        stdout: SplitParser {
            splitMarker: "\n"
            onRead: line => root.applyTrafficLine(line)
        }

        onExited: (exitCode, exitStatus) => {
            root.upSpeed = 0;
            root.downSpeed = 0;
            if (root.stoppingTraffic) {
                root.stoppingTraffic = false;
                return;
            }
            if (root.surfaceLive && root.configReady) {
                root.apiReachable = false;
                root.lastError = I18n.trFor("mihomoIndicator", "Cannot reach the mihomo API");
                trafficRestartTimer.restart();
            }
        }
    }

    Timer {
        id: trafficRestartTimer
        interval: 5000
        repeat: false
        onTriggered: root.updateTrafficStream()
    }

    // ---------- bar pill ----------

    readonly property color iconColor: apiReachable ? Theme.widgetIconColor : Theme.surfaceVariantText

    horizontalBarPill: Component {
        Row {
            spacing: Theme.spacingS

            DIcon {
                name: "network_check"
                size: root.glyphSize
                color: root.iconColor
                visible: !root.hideIcon
                anchors.verticalCenter: parent.verticalCenter
            }

            Row {
                visible: root.showSpeed
                spacing: Theme.spacingXS
                anchors.verticalCenter: parent.verticalCenter

                StyledText {
                    text: "↓"
                    color: Theme.info
                    font.pixelSize: root.barTextSize
                    anchors.verticalCenter: parent.verticalCenter
                }

                NumericText {
                    text: root.formatRate(root.downSpeed)
                    reserveText: "88.8 MB/s"
                    color: Theme.widgetTextColor
                    font.pixelSize: root.barTextSize
                    anchors.verticalCenter: parent.verticalCenter
                }
            }

            Row {
                visible: root.showSpeed
                spacing: Theme.spacingXS
                anchors.verticalCenter: parent.verticalCenter

                StyledText {
                    text: "↑"
                    color: Theme.error
                    font.pixelSize: root.barTextSize
                    anchors.verticalCenter: parent.verticalCenter
                }

                NumericText {
                    text: root.formatRate(root.upSpeed)
                    reserveText: "88.8 MB/s"
                    color: Theme.widgetTextColor
                    font.pixelSize: root.barTextSize
                    anchors.verticalCenter: parent.verticalCenter
                }
            }

            StyledText {
                text: root.proxyText
                visible: text !== ""
                color: Theme.widgetTextColor
                font.pixelSize: root.barTextSize
                width: Math.min(implicitWidth, 110)
                elide: Text.ElideRight
                anchors.verticalCenter: parent.verticalCenter
            }
        }
    }

    verticalBarPill: Component {
        Column {
            spacing: Theme.spacingXXS

            DIcon {
                name: "network_check"
                size: root.glyphSize
                color: root.iconColor
                visible: !root.hideIcon
                anchors.horizontalCenter: parent.horizontalCenter
            }

            NumericText {
                visible: root.showSpeed
                text: root.compactRate(root.downSpeed)
                color: Theme.info
                font.pixelSize: root.barTextSize
                anchors.horizontalCenter: parent.horizontalCenter
            }

            NumericText {
                visible: root.showSpeed
                text: root.compactRate(root.upSpeed)
                color: Theme.error
                font.pixelSize: root.barTextSize
                anchors.horizontalCenter: parent.horizontalCenter
            }
        }
    }

    // ---------- popout ----------

    popoutWidth: 430

    popoutContent: Component {
        MihomoPopout {
            plugin: root
        }
    }
}
