# stand-ins for the transport so the decoder can be tested on recorded gRPC messages
	.text
	.globl h2_connect, h2_request, on_bytes
h2_connect: ret
h2_request: ret
on_bytes: ret
	.bss
	.globl h2_phase, done_code, done_msg, done_len
h2_phase: .long 0
done_code: .long 0
done_len: .long 0
done_msg: .quad 0
