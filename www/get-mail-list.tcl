# /packages/intranet-mail-import/www/get-mail-list.tcl
#
# Copyright (C) 2003 - 2010 ]project-open[
#
# All rights reserved. Please check
# https://www.project-open.com/ for licensing details.

ad_page_contract {
    Show the list of mails assigned to this project 

    @author klaus.hofeditz@project-open.com
    @creation-date May 2012
} {
    object_id:integer
    { view_mode "json" }
}

	# additional security check required
	set user_id [auth::require_login]
	set object_type [db_string get_object_type "select acs_object_util__get_object_type(:object_id)" -default 0]
	set view_p 0

	# Admins can see everything 
	if { [im_is_user_site_wide_or_intranet_admin $user_id] } { set view_p 1	}

	# Users with privilege to see all mails can see everything 
        if { [im_permission $user_id view_mails_all] } { set view_p 1 }

	if { $object_type eq "im_user" && $object_id==$user_id } {
	   # User can see his own emails  
	   set view_p 1 
	} else {
		if { $object_type eq "im_project" } {
		    if { [im_biz_object_member_p $user_id $object_id] || [im_is_user_site_wide_or_intranet_admin $user_id] } { 
			set view_p 1 
		    }
		}
	}

        set ctr 0
	set json_record_list "" 

	if { $view_p } {
		set sql "
        	        select
                	        amb.*,
                        	to_char(ao.creation_date, 'YYYY-MM-DD') as date_formatted
	                from
        	                acs_rels ar,
                	        acs_mail_bodies amb,
                        	acs_objects ao
	                where
        	                ar.object_id_one = amb.body_id
                	        and amb.body_id = ao.object_id
                        	and ar.object_id_two = :object_id
	            "
		db_foreach mail_list $sql {
			append json_record_list "{\"id\":\"$content_item_id\",\n"
			append json_record_list "\"date\":\"$date_formatted\",\n"
		    	append json_record_list "\"subject\":\"[string map {\" \'} [mime::field_decode $header_subject]]\",\n"
			append json_record_list "\"from\":\"[string map {\" \'} $header_from]\",\n"
			append json_record_list "\"to\":\"[string map {\" \'} $header_to]\"\n"
			append json_record_list "},\n"
			incr ctr
		}
		set json_record_list [string range $json_record_list 0 [string length $json_record_list]-3]
	} 
	# else {set json_record_list [lang::message::lookup "" intranet-mail-import.No_View_Permission "You do not have permissions to view mails. Please contact your System Administrator"]}
