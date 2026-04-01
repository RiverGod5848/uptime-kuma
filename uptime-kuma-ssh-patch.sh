#!/bin/bash
# ============================================================
#  Uptime Kuma SSH Monitor Patch
#  支持：用户名密码 / 私钥 两种认证方式
#  用法: ./uptime-kuma-ssh-patch.sh [容器名]
#  默认容器名: uptime-kuma
# ============================================================
set -e

CONTAINER="${1:-uptime-kuma}"
TMPDIR=$(mktemp -d)
trap "rm -rf $TMPDIR" EXIT

echo "╔══════════════════════════════════════════════╗"
echo "║   Uptime Kuma SSH Monitor Patch  v2.0        ║"
echo "╚══════════════════════════════════════════════╝"
echo ""
echo "▶ 目标容器: $CONTAINER"
echo ""

if ! docker inspect "$CONTAINER" > /dev/null 2>&1; then
    echo "✗ 容器 '$CONTAINER' 不存在"; exit 1
fi
if [ "$(docker inspect -f '{{.State.Running}}' $CONTAINER)" != "true" ]; then
    echo "✗ 容器 '$CONTAINER' 未运行"; exit 1
fi
echo "✓ 容器运行正常"

# ============================================================
# 文件 1: SSH 监控类型后端
# ============================================================
cat > "$TMPDIR/ssh-monitor-type.js" << 'SSHEOF'
"use strict";

const { MonitorType } = require("./monitor-type");
const { UP } = require("../../src/util");
const { Client } = require("ssh2");

class SSHMonitorType extends MonitorType {

    name = "ssh";

    async check(monitor, heartbeat, _server) {
        const startTime  = Date.now();
        const host       = monitor.hostname;
        const port       = monitor.port || 22;
        const username   = monitor.basic_auth_user;
        const password   = monitor.basic_auth_pass;
        const privateKey = monitor.tlsKey;
        const authMethod = monitor.authMethod || "password";
        const command    = monitor.databaseQuery ? monitor.databaseQuery.trim() : "";
        const expected   = monitor.expectedValue ? monitor.expectedValue.trim() : "";
        const timeout    = (monitor.timeout || 10) * 1000;

        if (!host)     { throw new Error("SSH hostname is required"); }
        if (!username) { throw new Error("SSH username is required"); }
        if (!command)  { throw new Error("SSH command is required"); }

        if (authMethod === "key") {
            if (!privateKey || !privateKey.trim()) {
                throw new Error("SSH private key is required");
            }
        } else {
            if (!password) { throw new Error("SSH password is required"); }
        }

        await new Promise((resolve, reject) => {
            const conn = new Client();
            let settled = false;

            const done = (err) => {
                if (settled) { return; }
                settled = true;
                conn.end();
                if (err) { reject(err); } else { resolve(); }
            };

            const timer = setTimeout(() => {
                conn.destroy();
                done(new Error(`SSH timed out (${timeout / 1000}s)`));
            }, timeout);

            conn.on("ready", () => {
                conn.exec(command, (err, stream) => {
                    if (err) {
                        clearTimeout(timer);
                        return done(new Error("SSH exec error: " + err.message));
                    }
                    let stdout = "";
                    let stderr = "";
                    stream
                        .on("close", (code) => {
                            clearTimeout(timer);
                            heartbeat.ping = Date.now() - startTime;
                            if (expected !== "") {
                                if (stdout.includes(expected) || stderr.includes(expected)) {
                                    heartbeat.status = UP;
                                    heartbeat.msg    = `OK - output contains "${expected}"`;
                                    done();
                                } else {
                                    done(new Error(`Expected "${expected}" not found. stdout:[${stdout.trim()}] stderr:[${stderr.trim()}]`));
                                }
                            } else {
                                if (code === 0) {
                                    heartbeat.status = UP;
                                    heartbeat.msg    = stdout.trim() || "Command exited 0";
                                    done();
                                } else {
                                    done(new Error(`Command exited ${code}. stderr:[${stderr.trim()}]`));
                                }
                            }
                        })
                        .on("data", (data) => { stdout += data.toString(); })
                        .stderr.on("data", (data) => { stderr += data.toString(); });
                });
            });

            conn.on("error", (err) => {
                clearTimeout(timer);
                done(new Error("SSH connection failed: " + err.message));
            });

            const connectOptions = {
                host, port, username,
                readyTimeout:      timeout,
                keepaliveInterval: 0,
                hostVerifier:      () => true,
            };

            if (authMethod === "key") {
                connectOptions.privateKey = privateKey;
                if (password) { connectOptions.passphrase = password; }
            } else {
                connectOptions.password = password;
            }

            conn.connect(connectOptions);
        });
    }
}

module.exports = { SSHMonitorType };
SSHEOF
echo "✓ 生成 ssh-monitor-type.js"

# ============================================================
# 文件 2: Node.js 补丁脚本
# ============================================================
cat > "$TMPDIR/patch.js" << 'PATCHEOF'
"use strict";
const fs = require("fs");

// ─── 1. uptime-kuma-server.js ──────────────────────────────
const serverPath = "/app/server/uptime-kuma-server.js";
let srv = fs.readFileSync(serverPath, "utf8");

if (!srv.includes("SSHMonitorType")) {
    // 找到最后一个 require monitor-types 的行，在其后追加
    srv = srv.replace(
        `const { TailscalePing } = require("./monitor-types/tailscale-ping");`,
        `const { TailscalePing } = require("./monitor-types/tailscale-ping");\nconst { SSHMonitorType } = require("./monitor-types/ssh-monitor-type");`
    );
    srv = srv.replace(
        `UptimeKumaServer.monitorTypeList["tailscale-ping"] = new TailscalePing();`,
        `UptimeKumaServer.monitorTypeList["tailscale-ping"] = new TailscalePing();\n        UptimeKumaServer.monitorTypeList["ssh"] = new SSHMonitorType();`
    );
    fs.writeFileSync(serverPath, srv);
    console.log("✓ 已补丁 uptime-kuma-server.js");
} else {
    console.log("⚠ uptime-kuma-server.js 已补丁，跳过");
}

// ─── 2. EditMonitor.vue ────────────────────────────────────
const vuePath = "/app/src/pages/EditMonitor.vue";
let vue = fs.readFileSync(vuePath, "utf8");

// 移除旧 SSH 块（幂等），使用深度计数确保完整删除
function removeSSHBlocks(content) {
    const marker = "<!-- SSH Monitor Config -->";
    while (content.includes(marker)) {
        const start = content.indexOf(marker);
        // 向前找到该块起始的换行
        const lineStart = content.lastIndexOf("\n", start) + 1;
        // 从 marker 位置开始计数 <template> 深度
        let depth = 0;
        let i = start;
        let end = -1;
        while (i < content.length) {
            if (content.startsWith("<template", i)) {
                depth++;
                i += 9;
            } else if (content.startsWith("</template>", i)) {
                depth--;
                if (depth === 0) {
                    end = i + "</template>".length;
                    break;
                }
                i += 11;
            } else {
                i++;
            }
        }
        if (end === -1) break;
        // 吃掉后面的换行
        if (content[end] === "\n") end++;
        content = content.slice(0, lineStart) + content.slice(end);
    }
    return content;
}

vue = removeSSHBlocks(vue);
console.log("  移除旧 SSH 块完成");

// 加 SSH 选项到下拉（幂等）
if (!vue.includes('value="ssh"')) {
    vue = vue.replace(
        `                                        <option v-if="!$root.info.isContainer" value="tailscale-ping">
                                            Tailscale Ping
                                        </option>
                                    </optgroup>`,
        `                                        <option v-if="!$root.info.isContainer" value="tailscale-ping">
                                            Tailscale Ping
                                        </option>
                                        <option value="ssh">
                                            SSH
                                        </option>
                                    </optgroup>`
    );
}

// 加 SSH 到 hostname 条件（幂等）
if (!vue.includes("monitor.type === 'ssh'")) {
    vue = vue.replace(
        `monitor.type === 'tailscale-ping'" class="my-3">
                                <label for="hostname"`,
        `monitor.type === 'tailscale-ping' || monitor.type === 'ssh'" class="my-3">
                                <label for="hostname"`
    );
}

// SSH 专属配置块
const sshBlock = `
                            <!-- SSH Monitor Config -->
                            <template v-if="monitor.type === 'ssh'">

                                <!-- Port -->
                                <div class="my-3">
                                    <label for="ssh-port" class="form-label">{{ $t("Port") }}</label>
                                    <input id="ssh-port" v-model="monitor.port" type="number" class="form-control"
                                           min="1" max="65535" placeholder="22">
                                </div>

                                <!-- Username -->
                                <div class="my-3">
                                    <label for="ssh-username" class="form-label">{{ $t("Username") }}</label>
                                    <input id="ssh-username" v-model="monitor.basic_auth_user"
                                           type="text" class="form-control" required>
                                </div>

                                <!-- Auth 切换按钮 -->
                                <div class="my-3">
                                    <label class="form-label d-block">{{ $t("SSH Auth Method") }}</label>
                                    <div class="btn-group w-100" role="group">
                                        <button type="button"
                                                :class="['btn', (!monitor.authMethod || monitor.authMethod === 'password') ? 'btn-primary' : 'btn-outline-secondary']"
                                                @click="monitor.authMethod = 'password'">
                                            {{ $t("Password") }}
                                        </button>
                                        <button type="button"
                                                :class="['btn', monitor.authMethod === 'key' ? 'btn-primary' : 'btn-outline-secondary']"
                                                @click="monitor.authMethod = 'key'">
                                            {{ $t("SSH Private Key") }}
                                        </button>
                                    </div>
                                </div>

                                <!-- 密码认证 -->
                                <div v-if="!monitor.authMethod || monitor.authMethod === 'password'" class="my-3">
                                    <label for="ssh-password" class="form-label">{{ $t("Password") }}</label>
                                    <HiddenInput id="ssh-password" v-model="monitor.basic_auth_pass"
                                                 autocomplete="new-password"></HiddenInput>
                                </div>

                                <!-- 私钥认证 -->
                                <template v-if="monitor.authMethod === 'key'">
                                    <div class="my-3">
                                        <div class="d-flex justify-content-between align-items-center mb-1">
                                            <label for="ssh-private-key" class="form-label mb-0">{{ $t("SSH Private Key") }}</label>
                                            <button type="button" class="btn btn-outline-secondary btn-sm"
                                                    @click="$el.querySelector('#ssh-key-file').click()">
                                                {{ $t("Upload Key File") }}
                                            </button>
                                            <input id="ssh-key-file" type="file" style="display:none"
                                                   @change="handleSshKeyUpload">
                                        </div>
                                        <textarea id="ssh-private-key" v-model="monitor.tlsKey"
                                                  class="form-control font-monospace" rows="6"
                                                  placeholder="-----BEGIN OPENSSH PRIVATE KEY-----" required></textarea>
                                    </div>
                                    <div class="my-3">
                                        <div class="form-check">
                                            <input id="ssh-has-passphrase" class="form-check-input" type="checkbox"
                                                   v-model="monitor.sshHasPassphrase"
                                                   @change="if (!monitor.sshHasPassphrase) { monitor.basic_auth_pass = ''; }">
                                            <label class="form-check-label" for="ssh-has-passphrase">
                                                {{ $t("SSH Key Has Passphrase") }}
                                            </label>
                                        </div>
                                    </div>
                                    <div v-if="monitor.sshHasPassphrase" class="my-3">
                                        <label for="ssh-passphrase" class="form-label">{{ $t("SSH Key Passphrase") }}</label>
                                        <HiddenInput id="ssh-passphrase" v-model="monitor.basic_auth_pass"
                                                     autocomplete="new-password"></HiddenInput>
                                    </div>
                                </template>

                                <!-- Command -->
                                <div class="my-3">
                                    <label for="ssh-command" class="form-label">{{ $t("SSH Command") }}</label>
                                    <input id="ssh-command" v-model="monitor.databaseQuery"
                                           type="text" class="form-control" required
                                           placeholder="echo ok">
                                    <div class="form-text">{{ $t("sshCommandDescription") }}</div>
                                </div>

                                <!-- Expected Output -->
                                <div class="my-3">
                                    <label for="ssh-expected" class="form-label">
                                        {{ $t("SSH Expected Output") }}
                                        <span class="text-muted">({{ $t("optional") }})</span>
                                    </label>
                                    <input id="ssh-expected" v-model="monitor.expectedValue"
                                           type="text" class="form-control"
                                           placeholder="Leave empty to use exit code">
                                    <div class="form-text">{{ $t("sshExpectedDescription") }}</div>
                                </div>

                            </template>`;

vue = vue.replace(
    `            <div v-if="monitor.type === 'tailscale-ping'" class="alert alert-warning" role="alert">`,
    sshBlock + `\n\n                            <div v-if="monitor.type === 'tailscale-ping'" class="alert alert-warning" role="alert">`
);

// 添加 sshHasPassphrase 到 monitorDefaults（幂等）
if (!vue.includes("sshHasPassphrase")) {
    vue = vue.replace(
        "    authMethod: null,",
        "    authMethod: null,\n    sshHasPassphrase: false,"
    );
}

// ─── 注入 handleSshKeyUpload 方法（幂等）──────────────────
if (!vue.includes("handleSshKeyUpload")) {
    // 在 methods: { 后面插入
    vue = vue.replace(
        "methods: {",
        `methods: {
            handleSshKeyUpload(e) {
                const file = e.target.files && e.target.files[0];
                if (!file) { return; }
                const reader = new FileReader();
                reader.onload = (ev) => { this.monitor.tlsKey = ev.target.result; };
                reader.readAsText(file);
                e.target.value = "";
            },`
    );
}

fs.writeFileSync(vuePath, vue);
console.log("✓ 已补丁 EditMonitor.vue");

// ─── 3. en.json ────────────────────────────────────────────
const enPath = "/app/src/lang/en.json";
let en = JSON.parse(fs.readFileSync(enPath, "utf8"));

en["SSH Auth Method"]          = "Auth Method";
en["SSH Private Key"]          = "Private Key";
en["Upload Key File"]          = "Upload Key File";
en["SSH Key Has Passphrase"]   = "Key is protected by passphrase";
en["SSH Key Passphrase"]       = "Key Passphrase";
en["sshPassphraseDescription"] = "Leave empty if the private key has no passphrase.";
en["SSH Command"]              = "SSH Command";
en["sshCommandDescription"]    = "Command to execute after login. e.g. echo ok";
en["SSH Expected Output"]      = "Expected Output";
en["sshExpectedDescription"]   = "Output must contain this string to be UP. Leave empty: exit code 0 = UP.";
en["sshExpectedPlaceholder"]   = "Leave empty to use exit code";

fs.writeFileSync(enPath, JSON.stringify(en, null, 4));
console.log("✓ 已补丁 en.json");

console.log("\n所有补丁应用完成！");
PATCHEOF
echo "✓ 生成 patch.js"

# ============================================================
# 执行
# ============================================================

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Step 1/5  复制文件到容器"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
docker cp "$TMPDIR/ssh-monitor-type.js" "$CONTAINER:/app/server/monitor-types/ssh-monitor-type.js"
docker cp "$TMPDIR/patch.js"            "$CONTAINER:/tmp/patch.js"
echo "✓ 复制完成"

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Step 2/5  安装 ssh2 依赖"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
docker exec "$CONTAINER" bash -c "cd /app && npm install ssh2 --save --no-audit --no-fund 2>&1 | tail -3"
echo "✓ ssh2 就绪"

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Step 3/5  应用代码补丁"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
docker exec "$CONTAINER" node /tmp/patch.js

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Step 4/5  构建前端（约 1~2 分钟）"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
docker exec "$CONTAINER" bash -c "cd /app && npm run build 2>&1 | tail -5"
echo "✓ 前端构建完成"

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Step 5/5  重启容器"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
docker restart "$CONTAINER"
echo "✓ 容器已重启"

echo ""
echo "╔══════════════════════════════════════════════╗"
echo "║  ✅  SSH 监控插件安装完成！                  ║"
echo "║      [ Password ] [ Private Key ] 按钮切换   ║"
echo "╚══════════════════════════════════════════════╝"
