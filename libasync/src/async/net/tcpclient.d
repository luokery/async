module async.net.tcpclient;

debug import std.stdio;

import core.stdc.errno;
import core.stdc.string;
import core.thread;
import core.sync.mutex;

import std.socket;
import std.conv;
import std.string;

import async.event.selector;
import async.net.tcpstream;
import async.container.queue;
import async.thread;

class TcpClient : TcpStream
{
    debug
    {
        __gshared int thread_read_counter  = 0;
        __gshared int thread_write_counter = 0;
        __gshared int client_count         = 0;
        __gshared int socket_counter       = 0;
    }

    this(Selector selector, Socket socket)
    {
        super(socket);

        _selector      = selector;
        _writeQueue    = new Queue!(ubyte[])();

        _onRead        = new Task(&read,  cast(shared TcpClient)this);
        _onWrite       = new Task(&write, cast(shared TcpClient)this);

        _remoteAddress = remoteAddress.toString();
        _fd            = fd;

        debug
        {
            thread_read_counter++;
            thread_write_counter++;
            client_count++;
            socket_counter++;
        }
    }

    void termTask()
    {
        _terming = true;

        if (_onRead.state != Task.State.TERM)
        {
            while (_onRead.state != Task.State.HOLD)
            {
                Thread.sleep(50.msecs);
            }

            _onRead.call(-1);

            while (_onRead.state != Task.State.TERM)
            {
                Thread.sleep(0.msecs);
            }
        }

        if (_onWrite.state != Task.State.TERM)
        {
            while (_onWrite.state != Task.State.HOLD)
            {
                Thread.sleep(50.msecs);
            }

            _onWrite.call(-1);

            while (_onWrite.state != Task.State.TERM)
            {
                Thread.sleep(0.msecs);
            }
        }

        debug
        {
            client_count--;
            writeln("TermTask end.");
        }
    }

    void weakup(EventType et)
    {
        if (!_selector.runing || _terming)
        {
            return;
        }

        final switch (et)
        {
        case EventType.READ:
            _onRead.call();
            break;
        case EventType.WRITE:
            if (!_writeQueue.empty() || (_lastWriteOffset > 0))
            {
                _onWrite.call();
            }
            break;
        case EventType.ACCEPT:
        case EventType.READWRITE:
            break;
        }
    }

    private static void read(shared TcpClient _client)
    {
        TcpClient client = cast(TcpClient)_client;

        if (client._onRead !is null)
        {
            if (client._onRead.yield() < 0)
            {
                goto terminate;
            }
        }

        while (client._selector.runing && !client._terming && client.isAlive)
        {
            ubyte[]     data;
            ubyte[4096] buffer;

            while (client._selector.runing && !client._terming && client.isAlive)
            {
                long len = client._socket.receive(buffer);

                if (len > 0)
                {
                    data ~= buffer[0 .. cast(uint)len];

                    continue;
                }
                else if (len == 0)
                {
                    client._selector.removeClient(client.fd);
                    client.close();
                    data = null;

                    break;
                }
                else
                {
                    if (errno == EINTR)
                    {
                        continue;
                    }
                    else if (errno == EAGAIN || errno == EWOULDBLOCK)
                    {
                        break;
                    }
                    else
                    {
                        data = null;

                        break;
                    }
                }
            }

            if ((data.length > 0) && (client._selector.onReceive !is null))
            {
                client._selector.onReceive(client, data);
            }

            if (client._onRead !is null)
            {
                if (client._onRead.yield() < 0)
                {
                    break;
                }
            }
        }

    terminate:

        debug
        {
            client.thread_read_counter--;
        }

        if (client._onRead !is null)
        {
            client._onRead.terminate();
        }
    }

    private static void write(shared TcpClient _client)
    {
        TcpClient client = cast(TcpClient)_client;

        if (client._onWrite !is null)
        {
            if (client._onWrite.yield() < 0)
            {
                goto terminate;
            }
        }

        while (client._selector.runing && !client._terming && client.isAlive)
        {
            while (client._selector.runing && !client._terming && client.isAlive && (!client._writeQueue.empty() || (client._lastWriteOffset > 0)))
            {
                if (client._writingData.length == 0)
                {
                    client._writingData     = client._writeQueue.pop();
                    client._lastWriteOffset = 0;
                }

                while (client._selector.runing && !client._terming && client.isAlive && (client._lastWriteOffset < client._writingData.length))
                {
                    long len = client._socket.send(client._writingData[cast(uint)client._lastWriteOffset .. $]);

                    if (len > 0)
                    {
                        client._lastWriteOffset += len;

                        continue;
                    }
                    else if (len == 0)
                    {
                        //client._selector.removeClient(fd);
                        //client.close();

                        if (client._lastWriteOffset < client._writingData.length)
                        {
                            if (client._selector.onSendCompleted !is null)
                            {
                                client._selector.onSendCompleted(client._fd, client._remoteAddress, client._writingData, cast(size_t)client._lastWriteOffset);
                            }

                            debug writefln("The sending is incomplete, the total length is %d, but actually sent only %d.", client._writingData.length, client._lastWriteOffset);
                        }

                        client._writingData.length = 0;
                        client._lastWriteOffset    = 0;

                        goto yield; // sending is break and incomplete.
                    }
                    else
                    {
                        if (errno == EINTR)
                        {
                            continue;
                        }
                        else if (errno == EAGAIN || errno == EWOULDBLOCK)
                        {
                            goto yield;	// Wait eventloop notify to continue again;
                        }
                        else
                        {
                            client._writingData.length = 0;
                            client._lastWriteOffset    = 0;

                            goto yield; // Some error.
                        }
                    }
                }

                if (client._lastWriteOffset == client._writingData.length)
                {
                    if (client._selector.onSendCompleted !is null)
                    {
                        client._selector.onSendCompleted(client._fd, client._remoteAddress, client._writingData, cast(size_t)client._lastWriteOffset);
                    }

                    client._writingData.length = 0;
                    client._lastWriteOffset    = 0;
                }
            }

            if (client._writeQueue.empty() && (client._writingData.length == 0))
            {
                client._selector.reregister(client.fd, EventType.READ);
            }

        yield:

            if (client._onWrite !is null)
            {
                if (client._onWrite.yield() < 0)
                {
                    break;
                }
            }
        }

    terminate:

        debug
        {
            client.thread_write_counter--;
        }

        if (client._onWrite !is null)
        {
            client._onWrite.terminate();
        }
    }

    int send(ubyte[] data)
    {
        if (data.length == 0)
        {
            return -1;
        }

        if (!isAlive())
        {
            return -2;
        }

        _writeQueue.push(data);
        _selector.reregister(fd, EventType.READWRITE);

        return 0;
    }

    long send_withoutEventloop(in ubyte[] data)
    {
        if ((data.length == 0) || !_selector.runing || _terming || !_socket.isAlive())
        {
            return 0;
        }

        long sent = 0;

        while (_selector.runing && !_terming && isAlive && (sent < data.length))
        {
            long len = _socket.send(data[cast(uint)sent .. $]);

            if (len > 0)
            {
                sent += len;

                continue;
            }
            else if (len == 0)
            {
                break;
            }
            else
            {
                if (errno == EINTR)
                {
                    continue;
                }
                else if (errno == EAGAIN || errno == EWOULDBLOCK)
                {
                    Thread.sleep(50.msecs);

                    continue;
                }
                else
                {
                    break;
                }
            }
        }

        if (_selector.onSendCompleted !is null)
        {
            _selector.onSendCompleted(_fd, _remoteAddress, data, cast(size_t)sent);
        }

        if (sent != data.length)
        {
            debug writefln("The sending is incomplete, the total length is %d, but actually sent only %d.", data.length, sent);
        }

        return sent;
    }

    void close(int errno = 0)
    {
        _socket.shutdown(SocketShutdown.BOTH);
        _socket.close();

        debug
        {
            socket_counter--;
        }

        if ((errno != 0) && (_selector.onSocketError !is null))
        {
            _selector.onSocketError(_fd, _remoteAddress, fromStringz(strerror(errno)).idup);
        }

        if (_selector.onDisConnected !is null)
        {
            _selector.onDisConnected(_fd, _remoteAddress);
        }
    }

private:

    Selector           _selector;
    Queue!(ubyte[])    _writeQueue;
    ubyte[]            _writingData;
    size_t             _lastWriteOffset;

    Task               _onRead;
    Task               _onWrite;

    string             _remoteAddress;
    int                _fd;
    shared bool        _terming = false;
}
