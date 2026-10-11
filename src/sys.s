# Linux x86-64 syscalls, the heap, and the static memory block. No libc anywhere.
	.include "src/layout.inc"
	.text
	.globl sys_write, sys_read, sys_exit, sys_socket, sys_connect, sys_getrandom, sys_open, alloc, heap_init, mem, heap_ptr

# sys_write(fd, ptr, len) -> rax
sys_write:
	mov $1, %eax
	syscall
	ret

# sys_read(fd, ptr, len) -> rax (negative on error)
sys_read:
	xor %eax, %eax
	syscall
	ret

# sys_open(path, flags) -> fd
sys_open:
	mov $2, %eax
	xor %edx, %edx
	syscall
	ret

sys_exit:
	mov $60, %eax
	syscall

# sys_socket(domain, type, protocol)
sys_socket:
	mov $41, %eax
	syscall
	ret

# sys_connect(fd, addr, len)
sys_connect:
	mov $42, %eax
	syscall
	ret

# sys_getrandom(buf, len)
sys_getrandom:
	xor %edx, %edx
	mov $318, %eax
	syscall
	ret

# heap_init: one lazily committed anonymous mapping; nothing is ever freed
heap_init:
	xor %edi, %edi                 # addr
	mov $HEAP_SIZE, %esi           # len
	mov $3, %edx                   # PROT_READ|PROT_WRITE
	mov $0x4022, %r10d             # MAP_PRIVATE|MAP_ANONYMOUS|MAP_NORESERVE
	mov $-1, %r8
	xor %r9d, %r9d
	mov $9, %eax
	syscall
	mov %rax, heap_ptr(%rip)
	ret

# alloc(n) -> rax: bump allocator, 8-byte aligned, memory is zero (fresh pages)
alloc:
	mov heap_ptr(%rip), %rax
	lea 7(%rax,%rdi), %rcx
	and $-8, %rcx
	mov %rcx, heap_ptr(%rip)
	ret

	.bss
	.balign 4096
mem:	.space MEM_SIZE
heap_ptr: .quad 0
