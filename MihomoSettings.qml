import QtQuick
import Quickshell
import qs.Common
import qs.Widgets
import qs.DCommon.Widgets
import qs.Modules.Plugins
import "MihomoApi.js" as Api

PluginSettings {
    id: root

    pluginId: "mihomoIndicator"

    onPluginServiceChanged: Qt.callLater(() => {
        if (groupPicker && groupPicker.visible)
            groupPicker.scheduleReload();
    })

    Connections {
        target: SettingsData
        function onPluginSettingsChanged() {
            root.reloadChildValues();
        }
    }

    StyledText {
        width: parent.width
        text: I18n.trFor("mihomoIndicator", "Mihomo Indicator")
        font.pixelSize: Theme.fontSizeLarge
        font.weight: Font.Bold
        color: Theme.surfaceText
    }

    StringSetting {
        id: configSetting
        settingKey: "configPath"
        label: I18n.trFor("mihomoIndicator", "Config file")
        description: I18n.trFor("mihomoIndicator", "mihomo reads external-controller and secret from this file. It must be readable by your user.")
        placeholder: "/etc/mihomo/config.yaml"
        defaultValue: "/etc/mihomo/config.yaml"
        onValueChanged: groupPicker.scheduleReload()
    }

    StringSetting {
        id: apiSetting
        settingKey: "apiOverride"
        label: I18n.trFor("mihomoIndicator", "API address override")
        description: I18n.trFor("mihomoIndicator", "Leave empty to use external-controller from the config. Example: 127.0.0.1:9090")
        placeholder: "127.0.0.1:9090"
        defaultValue: ""
        onValueChanged: groupPicker.scheduleReload()
    }

    StringSetting {
        id: secretSetting
        settingKey: "secretOverride"
        label: I18n.trFor("mihomoIndicator", "API secret override")
        description: I18n.trFor("mihomoIndicator", "Leave empty to use the secret from the config file.")
        placeholder: ""
        defaultValue: ""
        onValueChanged: groupPicker.scheduleReload()
    }

    SliderSetting {
        settingKey: "refreshInterval"
        label: I18n.trFor("mihomoIndicator", "Refresh interval")
        description: I18n.trFor("mihomoIndicator", "How often the bar updates traffic and proxy state.")
        defaultValue: 2
        minimum: 1
        maximum: 30
        unit: "s"
    }

    ToggleSetting {
        settingKey: "showSpeed"
        label: I18n.trFor("mihomoIndicator", "Show traffic in the bar")
        description: I18n.trFor("mihomoIndicator", "Display current upload and download speed next to the icon.")
        defaultValue: true
    }

    ToggleSetting {
        settingKey: "hideIcon"
        label: I18n.trFor("mihomoIndicator", "Hide the leading icon")
        description: I18n.trFor("mihomoIndicator", "Show only the traffic rates in the bar.")
        defaultValue: false
    }

    ToggleSetting {
        settingKey: "showProxyName"
        label: I18n.trFor("mihomoIndicator", "Show selected proxy in the bar")
        description: I18n.trFor("mihomoIndicator", "Display the active node name of the selected proxy group.")
        defaultValue: false
    }

    StringSetting {
        settingKey: "displayGroup"
        label: I18n.trFor("mihomoIndicator", "Bar proxy group")
        description: I18n.trFor("mihomoIndicator", "Group shown in the bar. Leave empty to use the first visible Selector group. Example: Final")
        placeholder: "Final"
        defaultValue: ""
    }

    SelectionSetting {
        id: visibilitySetting
        settingKey: "groupVisibility"
        label: I18n.trFor("mihomoIndicator", "Group visibility")
        description: I18n.trFor("mihomoIndicator", "Choose which proxy groups appear in the popout.")
        options: [
            { label: I18n.trFor("mihomoIndicator", "Show all groups"), value: "all" },
            { label: I18n.trFor("mihomoIndicator", "Hide selected groups"), value: "hide" },
            { label: I18n.trFor("mihomoIndicator", "Show only selected groups"), value: "only" }
        ]
        defaultValue: "all"
        onValueChanged: {
            if (value !== "all")
                groupPicker.scheduleReload();
        }
    }

    Column {
        id: groupPicker
        width: parent.width
        spacing: Theme.spacingS
        visible: visibilitySetting.value !== "all"

        property var groups: []
        property var selected: []
        property string status: ""
        property bool loading: false

        function loadSelected() {
            const raw = root.loadValue("groupFilter", []);
            if (Array.isArray(raw)) {
                selected = raw;
                return;
            }
            if (typeof raw === "string" && raw.trim() !== "") {
                try {
                    const parsed = JSON.parse(raw);
                    if (Array.isArray(parsed)) {
                        selected = parsed;
                        return;
                    }
                } catch (error) {
                    // Fall through to the comma separated form.
                }
                selected = raw.split(",").map(item => item.trim()).filter(item => item !== "");
                return;
            }
            selected = [];
        }

        function scheduleReload() {
            reloadTimer.restart();
        }

        function reload() {
            loadSelected();
            loading = true;
            status = I18n.trFor("mihomoIndicator", "Loading groups…");

            const configPath = root.loadValue("configPath", "/etc/mihomo/config.yaml");
            const path = configPath.startsWith("~") ? (Quickshell.env("HOME") || "") + configPath.slice(1) : configPath;
            Proc.runCommand("mihomoIndicator.settings.config", ["cat", path], (text, exitCode) => {
                const config = Api.parseConfig(exitCode === 0 ? text : "");
                const override = root.loadValue("apiOverride", "");
                let base = "";
                let unixSocket = "";
                if (override !== "") {
                    base = Api.normalizeBase(override);
                } else if (config.unixSocket !== "") {
                    base = "http://localhost";
                    unixSocket = config.unixSocket;
                } else {
                    const endpoint = Api.endpointFromController(config.controller) || { host: "127.0.0.1", port: 9090 };
                    base = Api.baseUrl(endpoint.host, endpoint.port);
                }
                const secretOverride = root.loadValue("secretOverride", "");
                const secret = secretOverride !== "" ? secretOverride : config.secret;
                const command = Api.curlArgs(base, secret, unixSocket, "/proxies", "GET", null, 3);
                Proc.runCommand("mihomoIndicator.settings.proxies", command, (stdout, proxyExitCode) => {
                    loading = false;
                    const result = Api.parseResponse(stdout, proxyExitCode);
                    if (!result.ok) {
                        status = I18n.trFor("mihomoIndicator", "Cannot load proxy groups");
                        return;
                    }
                    try {
                        const names = Api.parseProxies(result.body).groups.map(item => item.name);
                        const order = config.groupOrder || [];
                        if (order.length > 0) {
                            const rank = {};
                            for (let i = 0; i < order.length; i++)
                                rank[order[i]] = i;
                            const serverIndex = {};
                            names.forEach((name, index) => serverIndex[name] = index);
                            names.sort((a, b) => {
                                const ra = rank[a];
                                const rb = rank[b];
                                const va = ra !== undefined ? ra : 100000 + serverIndex[a];
                                const vb = rb !== undefined ? rb : 100000 + serverIndex[b];
                                return va - vb;
                            });
                        }
                        groups = names;
                        status = I18n.trFor("mihomoIndicator", "%1 groups").arg(groups.length);
                    } catch (error) {
                        status = I18n.trFor("mihomoIndicator", "Cannot load proxy groups");
                    }
                }, 0, 6000, groupPicker);
            }, 0, 4000, groupPicker);
        }

        function toggle(name, enabled) {
            const next = selected.slice();
            const index = next.indexOf(name);
            if (enabled && index < 0)
                next.push(name);
            else if (!enabled && index >= 0)
                next.splice(index, 1);
            selected = next;
            root.saveValue("groupFilter", next);
        }

        function clearSelection() {
            selected = [];
            root.saveValue("groupFilter", []);
        }

        onVisibleChanged: {
            if (visible)
                scheduleReload();
        }

        Timer {
            id: reloadTimer
            interval: 300
            repeat: false
            onTriggered: groupPicker.reload()
        }

        StyledText {
            width: parent.width
            text: I18n.trFor("mihomoIndicator", "Select groups")
            color: Theme.surfaceText
            font.pixelSize: Theme.fontSizeMedium
        }

        StyledText {
            width: parent.width
            text: I18n.trFor("mihomoIndicator", "Pick the groups to hide, or the only groups to show, depending on the mode above.")
            color: Theme.surfaceVariantText
            font.pixelSize: Theme.fontSizeSmall
            wrapMode: Text.WordWrap
        }

        DFilterChips {
            width: parent.width
            multiSelect: true
            model: groupPicker.groups
            selectedValues: groupPicker.selected
            onSelectionToggled: (index, enabled) => groupPicker.toggle(groupPicker.groups[index], enabled)
        }

        Row {
            spacing: Theme.spacingS

            DButton {
                text: I18n.trFor("mihomoIndicator", "Refresh groups")
                iconName: "refresh"
                busy: groupPicker.loading
                onClicked: groupPicker.reload()
            }

            DButton {
                text: I18n.trFor("mihomoIndicator", "Clear selection")
                variant: "text"
                enabled: groupPicker.selected.length > 0
                onClicked: groupPicker.clearSelection()
            }

            StyledText {
                text: groupPicker.status
                color: Theme.surfaceVariantText
                font.pixelSize: Theme.fontSizeSmall
                anchors.verticalCenter: parent.verticalCenter
            }
        }
    }

    StringSetting {
        settingKey: "testUrl"
        label: I18n.trFor("mihomoIndicator", "Latency test URL")
        description: I18n.trFor("mihomoIndicator", "URL used by the latency test button.")
        placeholder: "https://www.gstatic.com/generate_204"
        defaultValue: "https://www.gstatic.com/generate_204"
    }

    SliderSetting {
        settingKey: "iconScale"
        label: I18n.trFor("mihomoIndicator", "Icon size")
        description: I18n.trFor("mihomoIndicator", "Scale the status icon relative to the bar's default icon size.")
        defaultValue: 100
        minimum: 50
        maximum: 200
        unit: "%"
    }
}
