<img width="64" height="64" alt="for DOS" src="https://github.com/user-attachments/assets/f53ec307-17a9-42f4-851f-9958938572bb" />

# REMPATH.EXE

[Download REMPATH.EXE](https://github.com/therenegar/rempath/blob/main/REMPATH.EXE) and place anywhere (ideally a location that is on PATH itself!)

### Usage

To remove a directory from your environment PATH statement (leaving everything else)
```
REMPATH C:\DIRECTORY
```
That's it. Just add the directory to remove as a parameter and REMPATH will do its thing.

The directory can be with or without a trailing backslash, in upper or lowercase.

If the directory occurs multiple times in PATH, all occurrences will be removed.
