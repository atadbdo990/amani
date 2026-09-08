{
  "log": {
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "port": __PORT__,
      "listen": "0.0.0.0",
      "protocol": "__PROTO__",
      "settings": {
        "clients": [
          {
            "id": "__USER_ID__",
            "password": "__USER_ID__",
            "level": 0
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "__NETWORK__",
        "security": "none",
        "tcpSettings": {
          "header": {
            "type": "none"
          }
        },
        "wsSettings": {
          "path": "__WS_PATH__",
          "host": "__HOST__"
        },
        "grpcSettings": {
          "serviceName": "__WS_PATH__"
        }
      },
      "sniffing": {
        "enabled": false,
        "destOverride": ["http", "tls"]
      }
    },
    {
      "port": 10085,
      "listen": "127.0.0.1",
      "protocol": "dokodemo-door",
      "settings": {
        "address": "127.0.0.1"
      },
      "tag": "api"
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom",
      "settings": {},
      "streamSettings": {
        "sockopt": {
          "tcpFastOpen": true
        }
      },
      "tag": "direct"
    },
    {
      "protocol": "freedom",
      "tag": "api"
    }
  ],
  "stats": {},
  "api": {
    "tag": "api",
    "services": ["StatsService"]
  },
  "routing": {
    "rules": [
      {
        "inboundTag": ["api"],
        "outboundTag": "api",
        "type": "field"
      }
    ]
  },
  "policy": {
    "levels": {
      "0": {
        "statsUserUplink": true,
        "statsUserDownlink": true,
        "bufferSize": 65536,
        "uplinkCapacity": __SPEED_LIMIT__,
        "downlinkCapacity": __SPEED_LIMIT__
      }
    },
    "system": {
      "statsInboundUplink": true,
      "statsInboundDownlink": true
    }
  }
}
