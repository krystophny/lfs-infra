! fay - Fast Archive Yielder
! Minimal package manager for LFS bootstrap
! Single-file Fortran with iso_c_binding to libarchive

program fay
    use, intrinsic :: iso_fortran_env, only: stderr => error_unit
    use, intrinsic :: iso_c_binding
    implicit none

    ! libarchive constants
    integer(c_int), parameter :: ARCHIVE_OK = 0
    integer(c_int), parameter :: ARCHIVE_EOF = 1
    integer(c_int), parameter :: ARCHIVE_WARN = -20
    integer(c_int), parameter :: ARCHIVE_EXTRACT_TIME = 4
    integer(c_int), parameter :: ARCHIVE_EXTRACT_PERM = 2
    integer(c_int), parameter :: ARCHIVE_EXTRACT_ACL = 32
    integer(c_int), parameter :: ARCHIVE_EXTRACT_FFLAGS = 64

    ! libarchive C bindings
    interface
        function archive_read_new() bind(c, name='archive_read_new')
            import :: c_ptr
            type(c_ptr) :: archive_read_new
        end function

        function archive_read_support_filter_all(ar) bind(c, name='archive_read_support_filter_all')
            import :: c_ptr, c_int
            type(c_ptr), value :: ar
            integer(c_int) :: archive_read_support_filter_all
        end function

        function archive_read_support_format_all(ar) bind(c, name='archive_read_support_format_all')
            import :: c_ptr, c_int
            type(c_ptr), value :: ar
            integer(c_int) :: archive_read_support_format_all
        end function

        function archive_read_open_filename(ar, fname, blksz) bind(c, name='archive_read_open_filename')
            import :: c_ptr, c_int, c_char, c_size_t
            type(c_ptr), value :: ar
            character(len=1, kind=c_char), intent(in) :: fname(*)
            integer(c_size_t), value :: blksz
            integer(c_int) :: archive_read_open_filename
        end function

        function archive_read_next_header(ar, entry) bind(c, name='archive_read_next_header')
            import :: c_ptr, c_int
            type(c_ptr), value :: ar
            type(c_ptr), intent(out) :: entry
            integer(c_int) :: archive_read_next_header
        end function

        function archive_entry_pathname(entry) bind(c, name='archive_entry_pathname')
            import :: c_ptr
            type(c_ptr), value :: entry
            type(c_ptr) :: archive_entry_pathname
        end function

        function archive_read_extract(ar, entry, flags) bind(c, name='archive_read_extract')
            import :: c_ptr, c_int
            type(c_ptr), value :: ar
            type(c_ptr), value :: entry
            integer(c_int), value :: flags
            integer(c_int) :: archive_read_extract
        end function

        function archive_read_free(ar) bind(c, name='archive_read_free')
            import :: c_ptr, c_int
            type(c_ptr), value :: ar
            integer(c_int) :: archive_read_free
        end function

        function archive_error_string(ar) bind(c, name='archive_error_string')
            import :: c_ptr
            type(c_ptr), value :: ar
            type(c_ptr) :: archive_error_string
        end function

        function c_strlen(s) bind(c, name='strlen')
            import :: c_ptr, c_size_t
            type(c_ptr), value :: s
            integer(c_size_t) :: c_strlen
        end function
    end interface

    character(len=256) :: cmd, arg1, arg2
    integer :: nargs

    nargs = command_argument_count()
    if (nargs < 1) then
        call usage()
        stop 1
    end if

    call get_command_argument(1, cmd)
    arg1 = ''
    arg2 = ''
    if (nargs >= 2) call get_command_argument(2, arg1)
    if (nargs >= 3) call get_command_argument(3, arg2)

    select case (trim(cmd))
    case ('i', 'install')
        if (len_trim(arg1) == 0) call die('usage: fay install <pkg.tar.xz>')
        call pkg_install(trim(arg1))
    case ('r', 'remove')
        if (len_trim(arg1) == 0) call die('usage: fay remove <pkgname>')
        call pkg_remove(trim(arg1))
    case ('l', 'list')
        call pkg_list()
    case ('q', 'query')
        if (len_trim(arg1) == 0) call die('usage: fay query <pkgname>')
        call pkg_query(trim(arg1))
    case ('f', 'files')
        if (len_trim(arg1) == 0) call die('usage: fay files <pkgname>')
        call pkg_files(trim(arg1))
    case ('v', 'version')
        print '(a)', 'fay 0.1.0 - Fast Archive Yielder'
    case default
        call usage()
        stop 1
    end select

contains

    subroutine usage()
        print '(a)', 'fay - Fast Archive Yielder'
        print '(a)', ''
        print '(a)', 'Usage: fay <command> [args]'
        print '(a)', ''
        print '(a)', 'Commands:'
        print '(a)', '  i, install <pkg.tar.xz>  Install package'
        print '(a)', '  r, remove <pkgname>      Remove package'
        print '(a)', '  l, list                  List installed packages'
        print '(a)', '  q, query <pkgname>       Query package info'
        print '(a)', '  f, files <pkgname>       List package files'
        print '(a)', '  v, version               Show version'
    end subroutine

    subroutine die(msg)
        character(len=*), intent(in) :: msg
        write(stderr, '(a,a)') 'fay: ', msg
        stop 1
    end subroutine

    subroutine pkg_install(archive_path)
        character(len=*), intent(in) :: archive_path
        character(len=512) :: pkgname, version, dbdir, dbfile, filesfile
        character(len=4096) :: line
        character(len=:), allocatable :: files_content
        type(c_ptr) :: ar, entry
        integer(c_int) :: r
        integer :: u, ios
        logical :: exists

        inquire(file=archive_path, exist=exists)
        if (.not. exists) call die('file not found: ' // archive_path)

        call parse_pkgname(archive_path, pkgname, version)
        if (len_trim(pkgname) == 0) call die('cannot parse package name')

        dbdir = get_dbdir() // '/' // trim(pkgname)
        dbfile = trim(dbdir) // '/info'
        filesfile = trim(dbdir) // '/files'

        call execute_command_line('mkdir -p ' // trim(dbdir), wait=.true.)

        ar = archive_read_new()
        if (.not. c_associated(ar)) call die('archive_read_new failed')

        r = archive_read_support_filter_all(ar)
        r = archive_read_support_format_all(ar)
        r = archive_read_open_filename(ar, trim(archive_path) // c_null_char, 10240_c_size_t)
        if (r /= 0) call die('cannot open archive: ' // archive_path)

        files_content = ''
        do
            r = archive_read_next_header(ar, entry)
            if (r == ARCHIVE_EOF) exit
            if (r /= ARCHIVE_OK) then
                call die('archive read error: ' // c_to_f_string(archive_error_string(ar)))
            end if

            line = c_to_f_string(archive_entry_pathname(entry))
            files_content = files_content // trim(line) // new_line('a')

            r = archive_read_extract(ar, entry, ARCHIVE_EXTRACT_TIME + ARCHIVE_EXTRACT_PERM + &
                                     ARCHIVE_EXTRACT_ACL + ARCHIVE_EXTRACT_FFLAGS)
            if (r /= ARCHIVE_OK .and. r /= ARCHIVE_WARN) then
                print '(a,a)', 'warning: ', trim(c_to_f_string(archive_error_string(ar)))
            end if
        end do

        r = archive_read_free(ar)

        open(newunit=u, file=trim(dbfile), status='replace', action='write', iostat=ios)
        if (ios == 0) then
            write(u, '(a)') trim(pkgname)
            write(u, '(a)') trim(version)
            close(u)
        end if

        open(newunit=u, file=trim(filesfile), status='replace', action='write', iostat=ios)
        if (ios == 0) then
            write(u, '(a)') trim(files_content)
            close(u)
        end if

        print '(a,a,a,a)', 'installed ', trim(pkgname), ' ', trim(version)
    end subroutine

    subroutine pkg_remove(pkgname)
        character(len=*), intent(in) :: pkgname
        character(len=512) :: dbdir, filesfile, line
        integer :: u, ios
        logical :: exists

        dbdir = get_dbdir() // '/' // trim(pkgname)
        filesfile = trim(dbdir) // '/files'

        inquire(file=filesfile, exist=exists)
        if (.not. exists) call die('package not installed: ' // pkgname)

        open(newunit=u, file=trim(filesfile), status='old', action='read', iostat=ios)
        if (ios /= 0) call die('cannot read files list')

        do
            read(u, '(a)', iostat=ios) line
            if (ios /= 0) exit
            if (len_trim(line) > 0) then
                call execute_command_line('rm -f /' // trim(line) // ' 2>/dev/null', wait=.true.)
            end if
        end do
        close(u)

        call execute_command_line('rm -rf ' // trim(dbdir), wait=.true.)
        print '(a,a)', 'removed ', trim(pkgname)
    end subroutine

    subroutine pkg_list()
        character(len=512) :: dbdir, cmd
        dbdir = get_dbdir()
        cmd = 'ls -1 ' // trim(dbdir) // ' 2>/dev/null'
        call execute_command_line(trim(cmd), wait=.true.)
    end subroutine

    subroutine pkg_query(pkgname)
        character(len=*), intent(in) :: pkgname
        character(len=512) :: dbdir, infofile, name, version
        integer :: u, ios
        logical :: exists

        dbdir = get_dbdir() // '/' // trim(pkgname)
        infofile = trim(dbdir) // '/info'

        inquire(file=infofile, exist=exists)
        if (.not. exists) then
            print '(a,a)', trim(pkgname), ' is not installed'
            return
        end if

        open(newunit=u, file=trim(infofile), status='old', action='read', iostat=ios)
        if (ios /= 0) then
            print '(a)', 'error reading package info'
            return
        end if

        read(u, '(a)', iostat=ios) name
        read(u, '(a)', iostat=ios) version
        close(u)

        print '(a,a,a,a)', trim(name), ' ', trim(version), ' [installed]'
    end subroutine

    subroutine pkg_files(pkgname)
        character(len=*), intent(in) :: pkgname
        character(len=512) :: dbdir, filesfile, line
        integer :: u, ios
        logical :: exists

        dbdir = get_dbdir() // '/' // trim(pkgname)
        filesfile = trim(dbdir) // '/files'

        inquire(file=filesfile, exist=exists)
        if (.not. exists) call die('package not installed: ' // pkgname)

        open(newunit=u, file=trim(filesfile), status='old', action='read', iostat=ios)
        if (ios /= 0) call die('cannot read files list')

        do
            read(u, '(a)', iostat=ios) line
            if (ios /= 0) exit
            if (len_trim(line) > 0) print '(a)', trim(line)
        end do
        close(u)
    end subroutine

    subroutine parse_pkgname(path, pkgname, version)
        character(len=*), intent(in) :: path
        character(len=*), intent(out) :: pkgname, version
        character(len=512) :: basename
        integer :: i, k, last_slash, first_dash

        pkgname = ''
        version = ''

        last_slash = 0
        do i = len_trim(path), 1, -1
            if (path(i:i) == '/') then
                last_slash = i
                exit
            end if
        end do
        basename = path(last_slash+1:)

        k = index(basename, '.pkg.tar')
        if (k > 0) basename = basename(1:k-1)
        k = index(basename, '.tar')
        if (k > 0) basename = basename(1:k-1)

        first_dash = 0
        do i = 1, len_trim(basename)
            if (basename(i:i) == '-') then
                if (i < len_trim(basename)) then
                    if (basename(i+1:i+1) >= '0' .and. basename(i+1:i+1) <= '9') then
                        first_dash = i
                        exit
                    end if
                end if
            end if
        end do

        if (first_dash > 0) then
            pkgname = basename(1:first_dash-1)
            version = basename(first_dash+1:)
        else
            pkgname = trim(basename)
            version = 'unknown'
        end if
    end subroutine

    function get_dbdir() result(path)
        character(len=256) :: path
        character(len=256) :: root
        call get_environment_variable('FAY_ROOT', root)
        if (len_trim(root) == 0) root = ''
        path = trim(root) // '/var/lib/fay'
    end function

    function c_to_f_string(cptr) result(fstr)
        type(c_ptr), intent(in) :: cptr
        character(len=4096) :: fstr
        character(len=1, kind=c_char), pointer :: carr(:)
        integer :: i, n
        integer(c_size_t) :: slen

        fstr = ''
        if (.not. c_associated(cptr)) return

        slen = c_strlen(cptr)
        n = int(slen)
        if (n <= 0 .or. n > 4096) return

        call c_f_pointer(cptr, carr, [n])
        do i = 1, n
            fstr(i:i) = carr(i)
        end do
    end function

end program fay
