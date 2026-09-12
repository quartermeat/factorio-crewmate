package main

import (
	"bytes"
	"encoding/binary"
	"errors"
	"fmt"
	"io"
	"net"
	"os"
	"strings"
	"time"
)

// Source RCON. Factorio speaks it verbatim, including splitting long replies
// across several packets, which is why reads keep going until the socket goes
// quiet rather than stopping at the first one.
const (
	packetResponse = 0
	packetCommand  = 2
	packetAuth     = 3

	readIdle = 150 * time.Millisecond
)

type RCON struct {
	conn net.Conn
	id   int32
}

func Dial(address, password string, timeout time.Duration) (*RCON, error) {
	conn, err := net.DialTimeout("tcp", address, timeout)
	if err != nil {
		return nil, fmt.Errorf("connect to %s: %w", address, err)
	}
	client := &RCON{conn: conn}
	if err := client.send(packetAuth, password); err != nil {
		conn.Close()
		return nil, err
	}
	id, _, err := client.read(timeout)
	if err != nil {
		conn.Close()
		return nil, err
	}
	if id == -1 {
		conn.Close()
		return nil, errors.New("rcon authentication failed: wrong password")
	}
	return client, nil
}

func (c *RCON) Close() error { return c.conn.Close() }

func (c *RCON) Exec(command string) (string, error) {
	if err := c.send(packetCommand, command); err != nil {
		return "", err
	}
	var reply strings.Builder
	deadline := 5 * time.Second
	for {
		_, body, err := c.read(deadline)
		if err != nil {
			if errors.Is(err, os.ErrDeadlineExceeded) && reply.Len() > 0 {
				return reply.String(), nil
			}
			return reply.String(), err
		}
		reply.WriteString(body)
		deadline = readIdle
	}
}

func (c *RCON) send(kind int32, body string) error {
	c.id++
	payload := new(bytes.Buffer)
	binary.Write(payload, binary.LittleEndian, c.id)
	binary.Write(payload, binary.LittleEndian, kind)
	payload.WriteString(body)
	payload.Write([]byte{0, 0})

	frame := new(bytes.Buffer)
	binary.Write(frame, binary.LittleEndian, int32(payload.Len()))
	frame.Write(payload.Bytes())

	c.conn.SetWriteDeadline(time.Now().Add(5 * time.Second))
	_, err := c.conn.Write(frame.Bytes())
	return err
}

func (c *RCON) read(timeout time.Duration) (int32, string, error) {
	c.conn.SetReadDeadline(time.Now().Add(timeout))
	var size int32
	if err := binary.Read(c.conn, binary.LittleEndian, &size); err != nil {
		return 0, "", err
	}
	if size < 10 || size > 8<<20 {
		return 0, "", fmt.Errorf("rcon: implausible packet size %d", size)
	}
	buffer := make([]byte, size)
	if _, err := io.ReadFull(c.conn, buffer); err != nil {
		return 0, "", err
	}
	id := int32(binary.LittleEndian.Uint32(buffer[0:4]))
	body := string(bytes.TrimRight(buffer[8:], "\x00"))
	return id, body, nil
}
