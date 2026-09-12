package main

import (
	"encoding/binary"
	"io"
	"net"
	"strings"
	"testing"
	"time"
)

// A stand-in for the game's RCON port: authenticates, then replies to commands
// with whatever the test queued, split across packets the way Factorio splits
// long output.
func fakeServer(t *testing.T, password string, replies map[string][]string) string {
	t.Helper()
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { listener.Close() })

	go func() {
		conn, err := listener.Accept()
		if err != nil {
			return
		}
		defer conn.Close()
		for {
			id, kind, body, err := readPacket(conn)
			if err != nil {
				return
			}
			switch kind {
			case packetAuth:
				if body != password {
					id = -1
				}
				writePacket(conn, id, packetResponse, "")
			case packetCommand:
				for _, chunk := range replies[body] {
					writePacket(conn, id, packetResponse, chunk)
				}
			}
		}
	}()
	return listener.Addr().String()
}

func readPacket(conn net.Conn) (int32, int32, string, error) {
	var size int32
	if err := binary.Read(conn, binary.LittleEndian, &size); err != nil {
		return 0, 0, "", err
	}
	buffer := make([]byte, size)
	if _, err := io.ReadFull(conn, buffer); err != nil {
		return 0, 0, "", err
	}
	id := int32(binary.LittleEndian.Uint32(buffer[0:4]))
	kind := int32(binary.LittleEndian.Uint32(buffer[4:8]))
	return id, kind, string(buffer[8 : len(buffer)-2]), nil
}

func writePacket(conn net.Conn, id, kind int32, body string) {
	payload := make([]byte, 0, len(body)+10)
	payload = binary.LittleEndian.AppendUint32(payload, uint32(id))
	payload = binary.LittleEndian.AppendUint32(payload, uint32(kind))
	payload = append(payload, body...)
	payload = append(payload, 0, 0)
	frame := binary.LittleEndian.AppendUint32(nil, uint32(len(payload)))
	conn.Write(append(frame, payload...))
}

func TestDialRejectsWrongPassword(t *testing.T) {
	address := fakeServer(t, "right", nil)
	if _, err := Dial(address, "wrong", time.Second); err == nil {
		t.Fatal("expected authentication to fail")
	} else if !strings.Contains(err.Error(), "authentication failed") {
		t.Fatalf("unhelpful error: %v", err)
	}
}

func TestExecJoinsSplitReplies(t *testing.T) {
	address := fakeServer(t, "secret", map[string][]string{
		"/sc rcon.print('x')": {`{"ok":true,`, `"result":{"long":"yes"}}`},
	})
	client, err := Dial(address, "secret", time.Second)
	if err != nil {
		t.Fatal(err)
	}
	defer client.Close()

	reply, err := client.Exec("/sc rcon.print('x')")
	if err != nil {
		t.Fatal(err)
	}
	if reply != `{"ok":true,"result":{"long":"yes"}}` {
		t.Fatalf("packets not rejoined: %q", reply)
	}
}
