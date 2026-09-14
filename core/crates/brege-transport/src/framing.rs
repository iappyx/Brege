//! Varints and length-prefixed Protobuf messages on QUIC streams.

use brege_proto::MAX_FRAME_LEN;
use prost::Message;

use crate::TransportError;

pub async fn read_varint(recv: &mut quinn::RecvStream) -> Result<Option<u64>, TransportError> {
    let mut value = 0u64;
    for i in 0..10 {
        let mut byte = [0u8; 1];
        match recv.read_exact(&mut byte).await {
            Ok(()) => {}
            // A clean end of stream before the first byte means "no more messages".
            Err(quinn::ReadExactError::FinishedEarly(0)) if i == 0 => return Ok(None),
            Err(e) => return Err(e.into()),
        }
        value |= u64::from(byte[0] & 0x7f) << (7 * i);
        if byte[0] & 0x80 == 0 {
            return Ok(Some(value));
        }
    }
    Err(TransportError::Protocol("varint too long"))
}

/// Writes one length-prefixed message.
pub async fn write_msg<M: Message>(
    send: &mut quinn::SendStream,
    msg: &M,
) -> Result<(), TransportError> {
    send.write_all(&brege_proto::encode_frame(msg)).await?;
    Ok(())
}

/// Reads one length-prefixed message; `None` when the peer finished the stream.
pub async fn read_msg<M: Message + Default>(
    recv: &mut quinn::RecvStream,
) -> Result<Option<M>, TransportError> {
    let Some(len) = read_varint(recv).await? else {
        return Ok(None);
    };
    let len = usize::try_from(len).map_err(|_| TransportError::Protocol("frame too large"))?;
    if len > MAX_FRAME_LEN {
        return Err(TransportError::Protocol("frame too large"));
    }
    let mut buf = vec![0u8; len];
    recv.read_exact(&mut buf).await?;
    Ok(Some(M::decode(buf.as_slice())?))
}
