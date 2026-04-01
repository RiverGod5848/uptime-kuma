"use strict";

const { MonitorType } = require("./monitor-type");
const { UP } = require("../../src/util");
const { Client } = require("ssh2");
const { authenticator } = require("otplib");

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
        const otpEnabled = monitor.sshOtpEnabled || false;
        const otpSecret  = monitor.sshOtpSecret ? monitor.sshOtpSecret.trim() : "";
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

        if (otpEnabled && !otpSecret) {
            throw new Error("SSH OTP secret is required when OTP is enabled");
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
                if (otpEnabled) {
                    // 私钥 + OTP：键盘交互补充 OTP
                    connectOptions.tryKeyboard = true;
                    conn.on("keyboard-interactive", (_name, _instructions, _lang, prompts, finish) => {
                        const responses = prompts.map(() => authenticator.generate(otpSecret));
                        finish(responses);
                    });
                }
            } else {
                if (otpEnabled) {
                    // 密码 + OTP：键盘交互，第一个提示回密码，后续回 OTP
                    connectOptions.tryKeyboard = true;
                    let passwordSent = false;
                    conn.on("keyboard-interactive", (_name, _instructions, _lang, prompts, finish) => {
                        const responses = prompts.map(() => {
                            if (!passwordSent) {
                                passwordSent = true;
                                return password;
                            }
                            return authenticator.generate(otpSecret);
                        });
                        finish(responses);
                    });
                } else {
                    connectOptions.password = password;
                }
            }

            conn.connect(connectOptions);
        });
    }
}

module.exports = { SSHMonitorType };
