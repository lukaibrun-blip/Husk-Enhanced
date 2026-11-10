/* SPDX-License-Identifier: GPL-2.0-or-later */
/* Synthetic 6 GiB address window: real Mach mappings, not an iOS emulator. */
#include <mach/mach.h>
#include <mach/mach_vm.h>
#include <sys/mman.h>
#include <errno.h>
#include <stdint.h>
#include <stdlib.h>
#define START 0x7000000000ULL
#define END 0x7180000000ULL
/* Constrains the production allocator's vm_map calls without dyld interposition. */
kern_return_t bounded_vm_map(vm_map_t t,vm_address_t*a,vm_size_t s,vm_address_t m,int f,mem_entry_name_port_t o,vm_offset_t off,boolean_t cp,vm_prot_t p,vm_prot_t max,vm_inherit_t inh){
 if(!(f&VM_FLAGS_ANYWHERE)) {
  if(*a<START || *a>END || s>END-*a)return KERN_INVALID_ADDRESS;
  mach_vm_address_t at = (mach_vm_address_t)*a;
  kern_return_t kr = mach_vm_map(t, &at, s, m, f, o, off, cp, p, max, inh);
  if (kr == KERN_SUCCESS) *a = (vm_address_t)at;
  return kr;
 }
 for(uint64_t pos=(START+m)&~m;pos<=END && s<=END-pos;pos+=0x10000000ULL){
  if(pos&m)continue;
  mach_vm_address_t at=pos;
  kern_return_t kr=mach_vm_map(t,&at,s,0,f&~VM_FLAGS_ANYWHERE,o,off,cp,p,max,inh);
  if(kr==KERN_SUCCESS){*a=at;return kr;}
 }
 return KERN_NO_SPACE;
}
