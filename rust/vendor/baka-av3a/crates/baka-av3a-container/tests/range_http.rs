use baka_av3a_container::range::{HttpRangeResponse, HttpRangeSession, RangeProbe, RangeRequest};
use std::{
    io::{Read, Write},
    net::{TcpListener, TcpStream},
    time::Duration,
};
#[path = "fixtures/range_file.rs"]
mod fixture;

#[test]
fn strict_http_status_identity_range_and_encoding_checks() {
    let session = HttpRangeSession::new(100, "\"asset-1\"").unwrap();
    let request = RangeRequest {
        id: 1,
        bytes: 10..20,
    };
    assert_eq!(request.range_header().unwrap(), "bytes=10-19");
    assert!(RangeRequest { id: 0, bytes: 0..0 }.range_header().is_err());
    for etag in ["W/\"weak\"", "bare", "\"newline\n\"", "\"a\"b\""] {
        assert!(HttpRangeSession::new(100, etag).is_err());
    }
    let body = [0; 10];
    for (status, range, etag, encoding, length, valid) in [
        (206, "bytes 10-19/100", "\"asset-1\"", "", 10, true),
        (206, "bytes 10-19/100", "\"asset-1\"", "identity", 10, true),
        (200, "bytes 10-19/100", "\"asset-1\"", "", 10, false),
        (416, "bytes */100", "\"asset-1\"", "", 10, false),
        (206, "bytes 11-20/100", "\"asset-1\"", "", 10, false),
        (206, "bytes 10-19/101", "\"asset-1\"", "", 10, false),
        (206, "bytes 10-19/100", "\"asset-2\"", "", 10, false),
        (206, "bytes 10-19/100", "", "", 10, false),
        (206, "bytes 10-19/100", "\"asset-1\"", "gzip", 10, false),
        (206, "bytes 10-19/100", "\"asset-1\"", "", 9, false),
        (206, "bytes 10-19/*", "\"asset-1\"", "", 10, false),
        (
            206,
            "bytes 10-18446744073709551615/100",
            "\"asset-1\"",
            "",
            10,
            false,
        ),
        (206, "bytes +10-19/100", "\"asset-1\"", "", 10, false),
    ] {
        let result = session.validate(
            &request,
            HttpRangeResponse {
                status,
                content_range: range,
                etag,
                content_encoding: encoding,
                body: &body[..length],
            },
        );
        assert_eq!(result.is_ok(), valid, "{status} {range} {etag} {encoding}");
    }
}

#[test]
fn real_loopback_http_fetches_tail_metadata_without_full_media() {
    let data = fixture::file(false, false, 200_000);
    let length = data.len();
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let address = listener.local_addr().unwrap();
    let (response_consumed, wait_consumed) = std::sync::mpsc::channel();
    let server = std::thread::spawn(move || {
        // Two metadata reads, then one coalesced batch for four packets.
        for _ in 0..3 {
            let (mut socket, _) = listener.accept().unwrap();
            socket
                .set_read_timeout(Some(Duration::from_secs(5)))
                .unwrap();
            socket
                .set_write_timeout(Some(Duration::from_secs(5)))
                .unwrap();
            let mut header = Vec::new();
            while !header.ends_with(b"\r\n\r\n") {
                let mut byte = [0];
                socket.read_exact(&mut byte).unwrap();
                header.push(byte[0]);
                assert!(header.len() < 4096);
            }
            let header = String::from_utf8(header).unwrap();
            assert!(header.contains("If-Range: \"asset-1\"\r\n"));
            assert!(header.contains("Accept-Encoding: identity\r\n"));
            let bounds = header
                .lines()
                .find_map(|l| l.strip_prefix("Range: bytes="))
                .unwrap();
            let (start, end) = bounds.split_once('-').unwrap();
            let start = start.parse::<usize>().unwrap();
            let end = end.parse::<usize>().unwrap();
            let body = &data[start..=end];
            let response_header = format!(
                "HTTP/1.1 206 Partial Content\r\nContent-Range: bytes {start}-{end}/{length}\r\nETag: \"asset-1\"\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
                body.len()
            );
            let mut response = response_header.into_bytes();
            response.extend_from_slice(body);
            socket.write_all(&response).unwrap();
            socket.flush().unwrap();
            // Keep the response socket alive until the client has validated the
            // complete body. A timed close can reset a slow Windows reader.
            wait_consumed.recv_timeout(Duration::from_secs(5)).unwrap();
        }
    });
    let session = HttpRangeSession::new(length, "\"asset-1\"").unwrap();
    let get = |r: &RangeRequest| {
        let mut socket = TcpStream::connect(address).unwrap();
        socket
            .set_read_timeout(Some(Duration::from_secs(5)))
            .unwrap();
        let request_header = format!(
            "GET /sample.mp4 HTTP/1.1\r\nHost: localhost\r\nRange: {}\r\nIf-Range: {}\r\nAccept-Encoding: identity\r\nConnection: close\r\n\r\n",
            r.range_header().unwrap(),
            session.if_range()
        );
        socket.write_all(request_header.as_bytes()).unwrap();

        let mut wire = Vec::new();
        while !wire.ends_with(b"\r\n\r\n") {
            let mut byte = [0];
            socket.read_exact(&mut byte).unwrap();
            wire.push(byte[0]);
            assert!(wire.len() < 4096);
        }
        let boundary = wire.len() - 4;
        let headers = std::str::from_utf8(&wire[..boundary]).unwrap();
        let value = |name: &str| headers.lines().find_map(|l| l.strip_prefix(name)).unwrap();
        assert_eq!(
            value("Content-Length: ").parse::<usize>().unwrap(),
            r.bytes.len()
        );
        let mut body = vec![0; r.bytes.len()];
        socket.read_exact(&mut body).unwrap();
        assert!(headers.starts_with("HTTP/1.1 206 "));
        session
            .validate(
                r,
                HttpRangeResponse {
                    status: 206,
                    content_range: value("Content-Range: "),
                    etag: value("ETag: "),
                    content_encoding: "",
                    body: &body,
                },
            )
            .unwrap();
        response_consumed.send(()).unwrap();
        body
    };
    let mut probe = RangeProbe::new(length).unwrap();
    let mut fetched = 0;
    while let Some(r) = probe.next_request().unwrap() {
        let bytes = get(&r);
        fetched += bytes.len();
        probe.accept(&r, &bytes).unwrap();
    }
    let track = probe.into_track().unwrap();
    let request = RangeRequest {
        id: 99,
        bytes: track.packet_range(0).unwrap().start..track.packet_range(3).unwrap().end,
    };
    let bytes = get(&request);
    fetched += bytes.len();
    for i in 0..4 {
        let r = track.packet_range(i).unwrap();
        track
            .validate_packet(
                i,
                &bytes[r.start - request.bytes.start..r.end - request.bytes.start],
            )
            .unwrap();
    }
    assert!(fetched < length / 2);
    server.join().unwrap();
}
