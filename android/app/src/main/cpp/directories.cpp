#include <jni.h>
#include <sys/inotify.h>
#include <sys/stat.h>
#include <dirent.h>
#include <fcntl.h>
#include <unistd.h>
#include <cerrno>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <memory>
#include <string>
#include <vector>

namespace {
std::string bytes(JNIEnv* env,jbyteArray value) {
  const auto n=env->GetArrayLength(value);std::string s(n,'\0');
  env->GetByteArrayRegion(value,0,n,reinterpret_cast<jbyte*>(s.data()));return s;
}
bool relative(const std::string& s) {
  if(s.rfind("Pictures/",0)!=0 && s.rfind("DCIM/",0)!=0)return false;
  if(s.empty() || s.back()!='/' || s.find('\0')!=std::string::npos || s.find('\\')!=std::string::npos)return false;
  size_t at=0;while(at<s.size()){auto end=s.find('/',at);auto part=s.substr(at,end-at);
    if(part.empty()||part=="."||part=="..")return false;at=end+1;}return true;
}
int walk(const std::string& root,const std::string& path) {
  if(!relative(path)){errno=EINVAL;return -1;}
  int fd=open(root.c_str(),O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);if(fd<0)return -1;
  size_t at=0;while(at<path.size()){auto end=path.find('/',at);auto part=path.substr(at,end-at);
    int next=openat(fd,part.c_str(),O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);int error=errno;close(fd);
    if(next<0){errno=error;return -1;}fd=next;at=end+1;}return fd;
}
bool samePath(int fd,const std::string& path) {
  struct stat held{},current{};
  if(fstat(fd,&held)!=0 || lstat(path.c_str(),&current)!=0 || !S_ISDIR(current.st_mode) ||
      held.st_dev!=current.st_dev || held.st_ino!=current.st_ino)return false;
  char proc[64],actual[4096];snprintf(proc,sizeof(proc),"/proc/self/fd/%d",fd);
  auto n=readlink(proc,actual,sizeof(actual));
  return n>=0 && static_cast<size_t>(n)<sizeof(actual) && std::string(actual,n)==path;
}
struct Session {
  int parent=-1,child=-1,watch=-1,wd=-1;bool invalid=false,created=false,seen=false;
  std::string path,name;
  ~Session(){if(child>=0)close(child);if(watch>=0)close(watch);if(parent>=0)close(parent);}
  bool events() {
    alignas(inotify_event) char buffer[8192];
    for(;;){auto count=read(watch,buffer,sizeof(buffer));
      if(count<0){if(errno==EINTR)continue;if(errno!=EAGAIN)invalid=true;break;}
      if(count==0){invalid=true;break;}
      size_t at=0;while(at<static_cast<size_t>(count)){
        if(static_cast<size_t>(count)-at<sizeof(inotify_event)){invalid=true;break;}
        auto* event=reinterpret_cast<inotify_event*>(buffer+at);
        if(sizeof(*event)+event->len>static_cast<size_t>(count)-at){invalid=true;break;}
        if(event->mask&(IN_Q_OVERFLOW|IN_IGNORED|IN_UNMOUNT|IN_DELETE_SELF|IN_MOVE_SELF))invalid=true;
        if(event->wd!=wd && !(event->mask&IN_Q_OVERFLOW))invalid=true;
        if(event->len && !name.empty()) {
          const auto length=strnlen(event->name,event->len);
          if(length==event->len){invalid=true;break;}
          if(name==std::string(event->name,length)) {
            if(event->mask&(IN_DELETE|IN_MOVED_FROM|IN_MOVED_TO))invalid=true;
            if((event->mask&IN_CREATE) && (event->mask&IN_ISDIR))seen=true;
          }
        }
        at+=sizeof(*event)+event->len;
      }
    }
    return !invalid;
  }
  bool verify() {
    if(!samePath(parent,path))invalid=true;
    if(created && (child<0 || !samePath(child,path+"/"+name)))invalid=true;
    return events() && (!created||seen);
  }
};
Session* session(jlong value){return reinterpret_cast<Session*>(static_cast<uintptr_t>(value));}
}
extern "C" JNIEXPORT jlong JNICALL Java_io_github_tantor_1d_phototree_NativeDirectories_begin(JNIEnv* e,jobject,jbyteArray root,jbyteArray path) {
  auto s=std::make_unique<Session>();const auto r=bytes(e,root),p=bytes(e,path);
  s->parent=walk(r,p);if(s->parent<0)return 0;
  s->path=r+"/"+p.substr(0,p.size()-1);if(!samePath(s->parent,s->path))return 0;
  s->watch=inotify_init1(IN_NONBLOCK|IN_CLOEXEC);if(s->watch<0)return 0;
  char proc[64];snprintf(proc,sizeof(proc),"/proc/self/fd/%d",s->parent);
  s->wd=inotify_add_watch(s->watch,proc,IN_ONLYDIR|IN_CREATE|IN_DELETE|IN_MOVED_FROM|IN_MOVED_TO|IN_MOVE_SELF|IN_DELETE_SELF|IN_UNMOUNT);
  if(s->wd<0 || !s->verify())return 0;
  return static_cast<jlong>(reinterpret_cast<uintptr_t>(s.release()));
}
extern "C" JNIEXPORT jint JNICALL Java_io_github_tantor_1d_phototree_NativeDirectories_create(JNIEnv*e,jobject,jlong value,jbyteArray input) {
  auto* s=session(value);auto name=bytes(e,input);
  if(!s || s->created || !s->verify())return 3;
  if(name.empty()||name[0]=='.'||name.size()>255||name.find('/')!=std::string::npos||name.find('\\')!=std::string::npos||name.find('\0')!=std::string::npos)return 2;
  s->name=name;
  if(mkdirat(s->parent,name.c_str(),0700)!=0)return errno==EEXIST?1:2;
  s->created=true;s->child=openat(s->parent,name.c_str(),O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);
  return s->verify()?0:3;
}
extern "C" JNIEXPORT jboolean JNICALL Java_io_github_tantor_1d_phototree_NativeDirectories_verify(JNIEnv*,jobject,jlong value) {
  auto* s=session(value);return s && s->verify();
}
extern "C" JNIEXPORT void JNICALL Java_io_github_tantor_1d_phototree_NativeDirectories_end(JNIEnv*,jobject,jlong value) {delete session(value);}
extern "C" JNIEXPORT jint JNICALL Java_io_github_tantor_1d_phototree_NativeDirectories_read(JNIEnv*e,jobject,jbyteArray root,jbyteArray path) {
  const auto r=bytes(e,root),p=bytes(e,path);int fd=walk(r,p);if(fd<0)return errno==ENOENT?2:3;
  struct stat before{},after{};if(fstat(fd,&before)!=0){close(fd);return 3;}
  int copy=fcntl(fd,F_DUPFD_CLOEXEC,0);DIR* dir=copy<0?nullptr:fdopendir(copy);
  if(!dir){if(copy>=0)close(copy);close(fd);return 3;}
  bool content=false;errno=0;while(auto* item=readdir(dir)){if(strcmp(item->d_name,".") && strcmp(item->d_name,".."))content=true;}
  const int error=errno;closedir(dir);
  const bool stable=fstat(fd,&after)==0 && before.st_ctim.tv_sec==after.st_ctim.tv_sec && before.st_ctim.tv_nsec==after.st_ctim.tv_nsec &&
    samePath(fd,r+"/"+p.substr(0,p.size()-1));close(fd);
  return error||!stable?3:content?1:0;
}

// Conventional final-check then nonrecursive removal. ENOTEMPTY preserves any
// contents arriving before the syscall; external path replacement is not locked.
extern "C" JNIEXPORT jint JNICALL Java_io_github_tantor_1d_phototree_NativeDirectories_removeEmpty(JNIEnv*e,jobject,jbyteArray root,jbyteArray path) {
  const auto r=bytes(e,root),p=bytes(e,path);
  if(!relative(p)||p=="Pictures/"||p=="DCIM/")return 1;
  const auto trimmed=p.substr(0,p.size()-1);const auto slash=trimmed.rfind('/');
  if(slash==std::string::npos)return 1;
  const auto parent=trimmed.substr(0,slash+1),name=trimmed.substr(slash+1);
  int fd=walk(r,parent);if(fd<0)return 2;
  int child=openat(fd,name.c_str(),O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);
  if(child<0){close(fd);return 1;}
  const bool stable=samePath(child,r+"/"+trimmed)&&samePath(fd,r+"/"+parent.substr(0,parent.size()-1));
  int outcome=stable?unlinkat(fd,name.c_str(),AT_REMOVEDIR):-1;const int error=errno;
  close(child);close(fd);
  return outcome==0?0:error==ENOTEMPTY||error==EEXIST?1:error==EACCES||error==EPERM?2:3;
}

extern "C" JNIEXPORT jobjectArray JNICALL Java_io_github_tantor_1d_phototree_NativeDirectories_entries(JNIEnv*e,jobject,jbyteArray root,jbyteArray path) {
  const auto r=bytes(e,root),p=bytes(e,path);int fd=walk(r,p);if(fd<0)return nullptr;
  int copy=fcntl(fd,F_DUPFD_CLOEXEC,0);DIR* dir=copy<0?nullptr:fdopendir(copy);
  if(!dir){if(copy>=0)close(copy);close(fd);return nullptr;}
  std::vector<std::string> names;bool valid=true;errno=0;
  while(auto* item=readdir(dir)) {
    if(!strcmp(item->d_name,".")||!strcmp(item->d_name,".."))continue;
    struct stat info{};
    if(fstatat(fd,item->d_name,&info,AT_SYMLINK_NOFOLLOW)!=0 || !S_ISREG(info.st_mode)){valid=false;break;}
    names.emplace_back(item->d_name);
  }
  if(errno || !samePath(fd,r+"/"+p.substr(0,p.size()-1)))valid=false;
  closedir(dir);close(fd);if(!valid)return nullptr;
  auto type=e->FindClass("[B");auto result=e->NewObjectArray(names.size(),type,nullptr);
  for(size_t i=0;i<names.size();i++) {auto value=e->NewByteArray(names[i].size());e->SetByteArrayRegion(value,0,names[i].size(),reinterpret_cast<const jbyte*>(names[i].data()));e->SetObjectArrayElement(result,i,value);e->DeleteLocalRef(value);}
  return result;
}
