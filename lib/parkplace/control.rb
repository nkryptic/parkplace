require 'parkplace/mimetypes_hash'

class Class
    def login_required
        include Camping::Session, ParkPlace::UserSession
    end
end

module ParkPlace::UserSession
    def service(*a)
        if @state.user_id
            @user = ParkPlace::Models::User.find @state.user_id
        end
        if @user
            super(*a)
        else
            redirect Controllers::CLogin
        end
        self
    end
end

module ParkPlace::Controllers
    class CHome < R '/control'
        login_required
        def get
            redirect CBuckets
        end
    end

    class CLogin < R '/control/login'
        include Camping::Session
        def get
            render :control, "Login", :login
        end
        def post
            @login = true
            @user = User.find_by_login @input.login
            if @user
                if @user.password == hmac_sha1( @input.password, @user.secret )
                    @state.user_id = @user.id
                    return redirect(CBuckets)
                else
                    @user.errors.add(:password, 'is incorrect')
                end
            else
                @user = User.new
                @user.errors.add(:login, 'not found')
            end
            render :control, "Login", :login
        end
    end

    class CLogout < R '/control/logout'
        login_required
        def get
            @state.clear
            redirect CHome
        end
    end

    class CBuckets < R '/control/buckets'
        login_required
        def get
            @buckets = Bucket.find_by_sql [%{
               SELECT b.*, COUNT(c.id) AS total_children
               FROM parkplace_bits b LEFT JOIN parkplace_bits c 
                        ON b.rgt > c.rgt AND c.lft > b.lft
               WHERE b.parent_id IS NULL AND b.owner_id = ?
               GROUP BY b.id ORDER BY b.name}, @user.id]
            render :control, 'Your Buckets', :buckets
        end
        def post
            Bucket.find_root(@input.bname)
            redirect CBuckets
        rescue NoSuchBucket
            bucket = Bucket.create(:name => @input.bname, :owner_id => @user.id)
            bucket.grant(:access => @input.bacl.to_i)
            redirect CBuckets
        end
    end

    class CFiles < R '/control/buckets/(.+)'
        login_required
        def get(bucket_name)
            @bucket = Bucket.find_root(bucket_name)
            only_can_read @bucket
            @files = Slot.find :all, :conditions => ['parent_id = ?', @bucket.id], :order => 'name'
            render :control, "/#{@bucket.name}", :files
        end
        def post(bucket_name)
            bucket = Bucket.find_root(bucket_name)
            only_can_write bucket

            tmpf = @input.upfile.tempfile
            readlen, md5 = 0, MD5.new
            while part = tmpf.read(BUFSIZE)
                readlen += part.size
                md5 << part
            end
            fileinfo = FileInfo.new
            fileinfo.mime_type = @input.upfile['type'] || "binary/octet-stream"
            fileinfo.size = readlen
            fileinfo.md5 = md5.hexdigest

            bucket_dir = File.join(STORAGE_PATH, bucket_name)
            fileinfo.path = File.join(bucket_dir, File.basename(tmpf.path))
            FileUtils.mkdir_p(bucket_dir)
            FileUtils.mv(tmpf.path, fileinfo.path)

            @input.fname = @input.upfile.filename if @input.fname.blank?
            slot = Slot.create(:name => @input.fname, :owner_id => @user.id, :meta => nil, :obj => fileinfo)
            bucket.add_child(slot)
            slot.grant(:access => @input.bacl.to_i)
            redirect CFiles, bucket_name
        end
    end

    class CFile < R '/control/buckets/(.+)/(.+)'
        login_required
        include ParkPlace::SlotGet
    end

    class CDeleteBucket < R '/control/delete/([^\/]+)'
        login_required
        def post(bucket_name, oid)
            bucket = Bucket.find_root(bucket_name)
            only_owner_of bucket

            if Slot.count(:conditions => ['parent_id = ?', bucket.id]) > 0
                raise BucketNotEmpty
            end
            bucket.destroy
            redirect CBuckets
        end
    end

    class CDeleteFile < R '/control/delete/(.+?)/(.+)'
        login_required
        def post(bucket_name, oid)
            bucket = Bucket.find_root bucket_name
            only_can_write bucket
            slot = bucket.find_slot(oid)
            slot.destroy
            redirect CFiles, bucket_name
        end
    end

    class CUsers < R '/control/users'
        login_required
        def get
            only_superusers
            @usero = User.new
            @users = User.find :all, :conditions => ['deleted != 1'], :order => 'login'
            render :control, "User List", :users
        end
        def post
            only_superusers
            @usero = User.new @input.user.merge(:activated_at => Time.now)
            if @usero.valid?
                @usero.save
                redirect CUsers
            else
                render :control, "New User", :user
            end
        end
    end

    class CUser < R '/control/users/(.+)'
        login_required
        def get(login)
            only_superusers
            @usero = User.find_by_login login
            render :control, "#{@usero.login}", :profile
        end
        def post(login)
            only_superusers
            @usero = User.find_by_login login
            @usero.update_attributes(@input.user)
            render :control, "#{@usero.login}", :profile
        end
    end

    class CProfile < R '/control/profile'
        login_required
        def get
            @usero = @user
            render :control, "Your Profile", :profile
        end
        def post
            @user.update_attributes(@input.user)
            @usero = @user
            render :control, "Your Profile", :profile
        end
    end

    class CStatic < R '/control/s/(.+)'
        def get(path)
            @headers['Content-Type'] = MIME_TYPES[path[/\.\w+$/, 0]] || "text/plain"
            @headers['X-Sendfile'] = File.join(ParkPlace::STATIC_PATH, path)
        end
    end
end

module ParkPlace::Views
    def control_tab(klass)
        opts = {:href => R(klass)}
        opts[:class] = (@env.PATH_INFO =~ /^#{opts[:href]}/ ? "active" : "inactive")
        opts
    end
    def control(str, view)
        html do
            head do
                title { "Park Place Control Center &raquo; " + str }
                script :language => 'javascript', :src => R(CStatic, 'js/prototype.js')
                # script :language => 'javascript', :src => R(CStatic, 'js/support.js')
                style "@import '#{self / R(CStatic, 'css/control.css')}';", :type => 'text/css'
            end
            body do
                div.page! do
                    if @user and not @login
                    div.menu do
                        ul do
                            li { a 'buckets', control_tab(CBuckets) }
                            li { a 'users',   control_tab(CUsers)   } if @user.superuser?
                            li { a 'profile', control_tab(CProfile) }
                            li { a 'logout',  control_tab(CLogout)  }
                        end
                    end
                    end
                    div.header! do
                        h1 "Park Place"
                        h2 str
                    end
                    div.content! do
                        __send__ "control_#{view}"
                    end
                end
            end
        end
    end

    def control_login
        control_loginform
    end

    def control_loginform
        form :method => 'post', :class => 'create' do
            errors_for @user if @user
            div.required do
                label 'User', :for => 'login'
                input.login! :type => 'text'
            end
            div.required do
                label 'Password', :for => 'password'
                input.password! :type => 'password'
            end
            input.loggo! :type => 'submit', :value => "Login"
        end
    end

    def control_buckets
        if @buckets.any?
            table :width => "100%" do
                thead do
                    th "Name"
                    th "Contains"
                    th "Updated on"
                    th "Permission"
                end
                tbody do
                    @buckets.each do |bucket|
                        tr do
                            th { a bucket.name, :href => R(CFiles, bucket.name) }
                            td "#{bucket.total_children rescue 0} files"
                            td bucket.updated_at
                            td bucket.access_readable
                        end
                    end
                end
            end
        else
            p "A sad day.  You have no buckets yet."
        end
        h3 "Create a Bucket"
        form :method => 'post', :class => 'create' do
            div.required do
                label 'Bucket Name', :for => 'bname'
                input :name => 'bname', :type => 'text'
            end
            div.required do
                label 'Permissions', :for => 'bacl'
                select :name => 'bacl' do
                    ParkPlace::CANNED_ACLS.sort.each do |acl, perm|
                        opts = {:value => perm}
                        opts[:selected] = true if acl == 'private'
                        option acl, opts
                    end
                end
            end
            input.newbucket! :type => 'submit', :value => "Create"
        end
    end

    def control_files
        table :width => "100%" do
            thead do
                th "File"
                th "Size"
                th "Updated on"
                th "Permission"
                th "Actions"
            end
            tbody do
                @files.each do |file|
                    tr do
                        th { a file.name, :href => R(CFile, @bucket.name, file.name) }
                        td number_to_human_size(file.obj.size)
                        td file.updated_at
                        td bucket.access_readable
                        td { a "Delete", :href => R(CDeleteFile, @bucket.name, file.name), :onClick => POST, :title => "Delete file #{file.name}" }
                    end
                end
            end
        end
        h3 "Upload a File"
        form :method => 'post', :enctype => 'multipart/form-data', :class => 'create' do
            div.required do
                input :name => 'upfile', :type => 'file'
            end
            div.optional do
                label 'File Name', :for => 'fname'
                input :name => 'fname', :type => 'text'
            end
            div.required do
                label 'Permissions', :for => 'facl'
                select :name => 'facl' do
                    ParkPlace::CANNED_ACLS.sort.each do |acl, perm|
                        opts = {:value => perm}
                        opts[:selected] = true if acl == 'private'
                        option acl, opts
                    end
                end
            end
            input.newfile! :type => 'submit', :value => "Create"
        end
    end

    def control_user
        control_userform
    end

    def control_userform
        form :action => R(CUsers), :method => 'post', :class => 'create' do
            errors_for @usero
            div.required do
                label 'Login', :for => 'user[login]'
                input.large :name => 'user[login]', :type => 'text', :value => @usero.login
            end
            div.required.inline do
                label 'Is a super-admin? ', :for => 'user[superuser]'
                checkbox 'user[superuser]', @usero.superuser
            end
            div.required do
                label 'Password', :for => 'user[password]'
                input.fixed :name => 'user[password]', :type => 'password'
            end
            div.required do
                label 'Password again', :for => 'user[password_confirmation]'
                input.fixed :name => 'user[password_confirmation]', :type => 'password'
            end
            div.required do
                label 'Email', :for => 'user[email]'
                input :name => 'user[email]', :type => 'text', :value => @usero.email
            end
            div.required do
                label 'Key (must be unique)', :for => 'user[key]'
                input.fixed.long :name => 'user[key]', :type => 'text', :value => @usero.key || generate_key
            end
            div.required do
                label 'Secret', :for => 'user[secret]'
                input.fixed.long :name => 'user[secret]', :type => 'text', :value => @usero.secret || generate_secret
            end
            input.newuser! :type => 'submit', :value => "Create"
        end
    end

    def control_users
        table :width => "100%" do
            thead do
                th "Login"
                th "Activated on"
            end
            tbody do
                @users.each do |user|
                    tr do
                        th { a user.login, :href => R(CUser, user.login) }
                        td user.activated_at
                    end
                end
            end
        end
        h3 "Create a User"
        control_userform
    end

    def control_profile
        form :method => 'post', :class => 'create' do
            errors_for @usero
            if @user.superuser?
                div.required.inline do
                    label 'Is a super-admin? ', :for => 'user[superuser]'
                    checkbox 'user[superuser]', @usero.superuser
                end
            end
            div.required do
                label 'Password', :for => 'user[password]'
                input.fixed :name => 'user[password]', :type => 'password'
            end
            div.required do
                label 'Password again', :for => 'user[password_confirmation]'
                input.fixed :name => 'user[password_confirmation]', :type => 'password'
            end
            div.required do
                label 'Email', :for => 'user[email]'
                input :name => 'user[email]', :type => 'text', :value => @usero.email
            end
            div.required do
                label 'Key', :for => 'key'
                h4 @usero.key
            end
            div.required do
                label 'Secret', :for => 'secret'
                h4 @usero.secret
            end
            input.newfile! :type => 'submit', :value => "Save"
            # input.regen! :type => 'submit', :value => "Generate New Keys"
        end
    end

    def number_to_human_size(size)
      case 
        when size < 1.kilobyte: '%d Bytes' % size
        when size < 1.megabyte: '%.1f KB'  % (size / 1.0.kilobyte)
        when size < 1.gigabyte: '%.1f MB'  % (size / 1.0.megabyte)
        when size < 1.terabyte: '%.1f GB'  % (size / 1.0.gigabyte)
        else                    '%.1f TB'  % (size / 1.0.terabyte)
      end.sub('.0', '')
    rescue
      nil
    end

    def checkbox(name, value)
        opts = {:name => name, :type => 'checkbox', :value => 1}
        opts[:checked] = "true" if value.to_i == 1
        input opts
    end
end
