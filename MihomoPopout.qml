import QtQuick
import qs.Common
import qs.Widgets
import qs.DCommon.Widgets
import qs.Modules.Plugins

PopoutComponent {
    id: popout

    required property var plugin

    // Empty string shows the group grid; a group name shows its node list.
    property string openGroup: ""

    readonly property var openGroupData: {
        if (openGroup === "")
            return null;
        const groups = plugin.proxyGroups;
        return groups.find(item => item.name === openGroup) || null;
    }

    function open(name) {
        openGroup = name;
        plugin.selectGroup(name);
    }

    function back() {
        openGroup = "";
    }

    function modeLabel(key) {
        switch (key) {
        case "global":
            return I18n.trFor("mihomoIndicator", "Global");
        case "direct":
            return I18n.trFor("mihomoIndicator", "Direct");
        case "rule":
            return I18n.trFor("mihomoIndicator", "Rule");
        }
        return key;
    }

    headerText: "Mihomo"
    detailsText: plugin.statusLine

    headerActions: Component {
        DIconButton {
            iconName: "refresh"
            tooltipText: I18n.trFor("mihomoIndicator", "Refresh")
            Accessible.name: I18n.trFor("mihomoIndicator", "Refresh")
            onClicked: popout.plugin.refreshNow()
        }
    }

    Item {
        width: 1
        height: Theme.spacingS
    }

    Column {
        width: parent.width
        spacing: Theme.spacingM

        Rectangle {
            width: parent.width
            height: errorColumn.implicitHeight + Theme.spacingM * 2
            radius: Theme.cornerRadiusM
            color: Theme.errorContainer
            visible: plugin.lastError !== ""

            Column {
                id: errorColumn
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                anchors.margins: Theme.spacingM
                spacing: Theme.spacingXS

                StyledText {
                    width: parent.width
                    text: plugin.lastError
                    color: Theme.onErrorContainer
                    font.pixelSize: Theme.fontSizeMedium
                    wrapMode: Text.WordWrap
                }

                StyledText {
                    width: parent.width
                    text: plugin.apiBase
                    color: Theme.onErrorContainer
                    opacity: 0.75
                    font.pixelSize: Theme.fontSizeSmall
                    wrapMode: Text.WordWrap
                }
            }
        }

        StyledText {
            width: parent.width
            visible: plugin.configError !== ""
            text: plugin.configError + " · " + plugin.configPath
            color: Theme.surfaceVariantText
            font.pixelSize: Theme.fontSizeSmall
            wrapMode: Text.WordWrap
        }

        Item {
            width: parent.width
            height: Math.max(modeRow.height, testLatency.height)

            Row {
                id: modeRow
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                spacing: Theme.spacingS

                Repeater {
                    model: ["rule", "global", "direct"]

                    delegate: DButton {
                        required property string modelData
                        text: popout.modeLabel(modelData)
                        variant: popout.plugin.mode === modelData ? "filled" : "outlined"
                        enabled: popout.plugin.apiReachable
                        onClicked: popout.plugin.setMode(modelData)
                    }
                }
            }

            DButton {
                id: testLatency
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                text: I18n.trFor("mihomoIndicator", "Test latency")
                iconName: "speed"
                busy: popout.plugin.testing
                enabled: popout.plugin.apiReachable
                onClicked: popout.plugin.testGroup(popout.openGroup)
            }
        }

        // ---------- group grid ----------

        Column {
            width: parent.width
            spacing: Theme.spacingS
            visible: popout.openGroup === "" || popout.openGroupData === null

            Item {
                width: parent.width
                height: groupsTitle.height

                StyledText {
                    id: groupsTitle
                    anchors.left: parent.left
                    text: I18n.trFor("mihomoIndicator", "Proxy groups")
                    color: Theme.surfaceText
                    font.pixelSize: Theme.fontSizeMedium
                    font.weight: Font.Medium
                }

                StyledText {
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    text: popout.plugin.visibleGroups.length
                    color: Theme.surfaceVariantText
                    font.pixelSize: Theme.fontSizeSmall
                }
            }

            DGridView {
                id: groupGrid
                width: parent.width
                height: Math.min(320, Math.max(88, Math.ceil(popout.plugin.visibleGroups.length / 2) * 88))
                cellWidth: width / 2
                cellHeight: 88
                clip: true
                visible: popout.plugin.visibleGroups.length > 0
                model: popout.plugin.visibleGroups

                delegate: Item {
                    id: groupCard
                    width: groupGrid.cellWidth
                    height: groupGrid.cellHeight

                    Rectangle {
                        anchors.fill: parent
                        anchors.margins: Theme.spacingXS
                        radius: Theme.cornerRadiusM
                        color: cardMouse.containsMouse ? Theme.surfaceContainerHighest : Theme.surfaceContainerHigh
                        border.width: 1
                        border.color: cardMouse.containsMouse ? Theme.primary : Theme.outlineVariant

                        Row {
                            anchors.fill: parent
                            anchors.margins: Theme.spacingM
                            spacing: Theme.spacingS

                            Column {
                                width: Math.max(0, parent.width - chevron.width - Theme.spacingS)
                                anchors.verticalCenter: parent.verticalCenter
                                spacing: Theme.spacingXS

                                StyledText {
                                    width: parent.width
                                    text: modelData.name
                                    color: Theme.surfaceText
                                    font.pixelSize: Theme.fontSizeMedium
                                    font.weight: Font.Medium
                                    elide: Text.ElideRight
                                }

                                StyledText {
                                    width: parent.width
                                    text: modelData.now || I18n.trFor("mihomoIndicator", "None")
                                    color: Theme.surfaceVariantText
                                    font.pixelSize: Theme.fontSizeSmall
                                    elide: Text.ElideRight
                                }

                                StyledText {
                                    width: parent.width
                                    text: modelData.type + " · " + I18n.trFor("mihomoIndicator", "%1 nodes").arg(modelData.nodes.length)
                                    color: Theme.surfaceVariantText
                                    opacity: 0.7
                                    font.pixelSize: Theme.fontSizeSmall
                                    elide: Text.ElideRight
                                }
                            }

                            DIcon {
                                id: chevron
                                anchors.verticalCenter: parent.verticalCenter
                                name: "chevron_right"
                                size: 18
                                color: cardMouse.containsMouse ? Theme.primary : Theme.surfaceVariantText
                            }
                        }

                        MouseArea {
                            id: cardMouse
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            Accessible.role: Accessible.Button
                            Accessible.name: modelData.name
                            onClicked: popout.open(modelData.name)
                        }
                    }
                }
            }

            StyledText {
                width: parent.width
                visible: popout.plugin.visibleGroups.length === 0
                text: I18n.trFor("mihomoIndicator", "No proxy groups match the filter")
                color: Theme.surfaceVariantText
                font.pixelSize: Theme.fontSizeSmall
                wrapMode: Text.WordWrap
            }
        }

        // ---------- node list ----------

        Column {
            width: parent.width
            spacing: Theme.spacingM
            visible: popout.openGroup !== "" && popout.openGroupData !== null

            Item {
                width: parent.width
                height: Math.max(backButton.height, titleColumn.implicitHeight)

                DIconButton {
                    id: backButton
                    anchors.left: parent.left
                    anchors.verticalCenter: parent.verticalCenter
                    iconName: "arrow_back"
                    tooltipText: I18n.trFor("mihomoIndicator", "Back")
                    Accessible.name: I18n.trFor("mihomoIndicator", "Back")
                    onClicked: popout.back()
                }

                Column {
                    id: titleColumn
                    anchors.left: backButton.right
                    anchors.leftMargin: Theme.spacingS
                    anchors.verticalCenter: parent.verticalCenter
                    width: Math.max(0, parent.width - backButton.width - Theme.spacingS)
                    spacing: 2

                    StyledText {
                        width: parent.width
                        text: popout.openGroupData ? popout.openGroupData.name : ""
                        color: Theme.surfaceText
                        font.pixelSize: Theme.fontSizeMedium
                        font.weight: Font.Medium
                        elide: Text.ElideRight
                    }

                    StyledText {
                        width: parent.width
                        text: popout.openGroupData ? popout.openGroupData.type + " · " + I18n.trFor("mihomoIndicator", "%1 nodes").arg(popout.openGroupData.nodes.length) : ""
                        color: Theme.surfaceVariantText
                        font.pixelSize: Theme.fontSizeSmall
                        elide: Text.ElideRight
                    }
                }
            }

            DListView {
                id: nodeList
                width: parent.width
                height: Math.min(260, Math.max(40, (popout.openGroupData ? popout.openGroupData.nodes.length : 0) * 40))
                clip: true
                model: popout.openGroupData ? popout.openGroupData.nodes : []

                delegate: Rectangle {
                    id: nodeRow
                    width: nodeList.width
                    height: 40
                    radius: Theme.cornerRadiusS
                    color: rowMouse.containsMouse ? Theme.surfaceContainerHighest : "transparent"

                    readonly property bool current: popout.openGroupData !== null && popout.openGroupData.now === modelData

                    Row {
                        anchors.left: parent.left
                        anchors.leftMargin: Theme.spacingS
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: Theme.spacingS

                        DIcon {
                            name: nodeRow.current ? "radio_button_checked" : "radio_button_unchecked"
                            size: 16
                            color: nodeRow.current ? Theme.primary : Theme.surfaceVariantText
                            anchors.verticalCenter: parent.verticalCenter
                        }

                        StyledText {
                            width: Math.max(0, nodeList.width - 180)
                            text: modelData
                            color: Theme.surfaceText
                            font.pixelSize: Theme.fontSizeMedium
                            elide: Text.ElideRight
                            anchors.verticalCenter: parent.verticalCenter
                        }
                    }

                    Row {
                        anchors.right: parent.right
                        anchors.rightMargin: Theme.spacingS
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: Theme.spacingS

                        StyledText {
                            text: popout.plugin.proxyInfo[modelData] ? popout.plugin.proxyInfo[modelData].type : ""
                            color: Theme.surfaceVariantText
                            font.pixelSize: Theme.fontSizeSmall
                            anchors.verticalCenter: parent.verticalCenter
                        }

                        DBadge {
                            text: popout.plugin.delayText(modelData)
                            textColor: popout.plugin.delayColor(modelData)
                            color: Theme.surfaceContainerHighest
                            anchors.verticalCenter: parent.verticalCenter
                        }
                    }

                    MouseArea {
                        id: rowMouse
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: popout.openGroupData && popout.openGroupData.type === "Selector" ? Qt.PointingHandCursor : Qt.ArrowCursor
                        Accessible.role: Accessible.Button
                        Accessible.name: modelData
                        onClicked: popout.plugin.selectNode(modelData, popout.openGroup)
                    }
                }
            }
        }

        // ---------- totals ----------

        Item {
            width: parent.width
            height: totals.height

            Row {
                id: totals
                anchors.left: parent.left
                spacing: Theme.spacingM

                StyledText {
                    text: "↑ " + popout.plugin.formatBytes(popout.plugin.upTotal)
                    color: Theme.surfaceVariantText
                    font.pixelSize: Theme.fontSizeSmall
                }

                StyledText {
                    text: "↓ " + popout.plugin.formatBytes(popout.plugin.downTotal)
                    color: Theme.surfaceVariantText
                    font.pixelSize: Theme.fontSizeSmall
                }
            }

            StyledText {
                anchors.right: parent.right
                text: I18n.trFor("mihomoIndicator", "%1 connections").arg(popout.plugin.connectionCount)
                color: Theme.surfaceVariantText
                font.pixelSize: Theme.fontSizeSmall
            }
        }
    }
}
