import QtQuick
import qs.Common

QtObject {
    function check(done) {
        Proc.runCommand("mihomoIndicator.depCheck", ["sh", "-c", "command -v curl"], (stdout, exitCode) => {
            if (exitCode === 0) {
                done(null);
                return;
            }
            done({
                "title": I18n.trFor("mihomoIndicator", "Missing curl"),
                "details": I18n.trFor("mihomoIndicator", "This plugin talks to the mihomo API through curl.\n\nInstall curl, make sure it is on PATH, then enable the plugin again.")
            });
        }, 0, 4000, null);
    }
}
