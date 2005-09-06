ad_library {

    Reads mail from a Maildir and adds it to OpenACS and ]project-open[
    
    @author Eric Lorenzo (eric@openforce.net)
    @author Frank Bergmann (frank.bergmann@project-open.com)
    @creation-date 9 August 2005
    @cvs-id $Id$

}

namespace eval im_mail_import {

    ad_proc -public get_package_id {} {
	@returns package_id of this package
    } {
        return [apm_package_id_from_key intranet-mail-import]
    }
    
    ad_proc -private mail_dir {} {
	@returns incoming mail directory to be scanned for bounces
    } {
	set mail_dir [parameter::get -package_id [get_package_id] -parameter "MailDir" -default ""]
	if {"" == $mail_dir} {
	    ns_log Notice "im_mail_import.mail_dir: Didn't find parameter 'MailDir'"
	}
	ns_log Notice "im_mail_import.mail_dir: mail_dir=$mail_dir"
	return $mail_dir
    }
    
    ad_proc -public parse_email_address {
	-email:required
    } {
	Extracts the email address out of a mail address (like Joe User <joe@user.com>)
	@option email mail address to be parsed
	@returns only the email address part of the mail address
    } {
        if {![regexp {<([^>]*)>} $email all clean_email]} {
            return $email
        } else {
            return $clean_email
        }
    }

    ad_proc -public extract_emails { line } {
        Extract all emails (asdf@sdfg.dfg) from an email header line

        @option header_line A mail header like such as "from" or "to".
    } {
	ns_log Notice "im_mail_import.extract_emails: line=$line"
	
	set line [string tolower $line]
	regsub -all {\<} $line " " line
	regsub -all {\>} $line " " line
	regsub -all {\"} $line " " line

	set tokens [split $line " "]
	set emails [list]

	foreach token $tokens {
	    if {[regexp {^[a-z0-9_\.\-]+\@[a-z0-9_\.\-]+\.[a-z0-9_\.\-]+$} $token match ]} {
		lappend emails $token
	    }
	}

	ns_log Notice "im_mail_import.extract_emails: email=$emails"
	return $emails
    }


    ad_proc -public map_emails_to_ids { email_list } {
	Maps a list of emails to a list of User-IDs.
	Skips emails that are not present in the system.

        @option email_list A list of email address
    } {
	ns_log Notice "im_mail_import.map_emails_to_ids: email_list=$email_list"
        set ids [list]

        foreach email $email_list {
	    set id [db_string get_party "
		select party_id 
		from parties 
		where lower(email) = lower(:email)
	    " -default ""]

	    if {"" != $id} {
		append ids $id
	    }
        }
	ns_log Notice "im_mail_import.map_emails_to_ids: ids=$ids"
        return $ids
    }


    ad_proc -public process_mails {
        -mail_dir:required
    } {
        Processes all emails in MailDir
        @option mail_dir Maildir location
    } {
	set debug "\n"

	# Make sure the "Maildir/spam" folder exists"
	set spam_folder "$mail_dir/spam"
	if {![file exists $spam_folder]} {
	    if {[catch { ns_mkdir $spam_folder } errmsg]} {
		ns_log Notice "im_mail_import.process_mails: Error creating '$spam_folder' folder: '$errmsg'"
		append debug "Error creating '$spam_folder' folder: '$errmsg'\n"
		return $debug
	    }
	}

	# Make sure the "Maildir/defered" folder exists"
	set defered_folder "$mail_dir/defered"
	if {![file exists $defered_folder]} {
	    if {[catch { ns_mkdir $defered_folder } errmsg]} {
		ns_log Notice "im_mail_import.process_mails: Error creating '$defered_folder' folder: '$errmsg'"
		append debug "Error creating '$defered_folder' folder: '$errmsg'\n"
		return $debug
	    }
	}

	# Make sure the "Maildir/processed" folder exists"
	set processed_folder "$mail_dir/processed"
	if {![file exists $processed_folder]} {
	    if {[catch { ns_mkdir $processed_folder } errmsg]} {
		ns_log Notice "im_mail_import.process_mails: Error creating '$processed_folder' folder: '$errmsg'"
		append debug "im_mail_import.process_mails: Error creating '$processed_folder' folder: '$errmsg'\n"
		return $debug
	    }
	}

        if {[catch {
            set messages [glob "$mail_dir/new/*"]
        } errmsg]} {
            ns_log Notice "im_mail_import.process_mails: No messages: '$errmsg'"
            append debug "No messages: '$errmsg'\n"
            return $debug
        }

        set list_of_bounce_ids [list]
        set new_messages_p 0


	if {0 == [llength $messages]} {
            append debug "no messages in $mail_dir/new/\n"
	}

	# foreach incoming mail
        foreach msg $messages {
            ns_log Notice "im_mail_import.process_mails: mail $msg"
            append debug "mail $msg\n"

	    # Get the last piece of the Msg
	    set msg_paths [split $msg "/"]
	    set msg_body [lindex $msg_paths [expr [llength $msg_paths] - 1] ]

	    # Read the entire mail into memory...
            if [catch {
		set f [open $msg r]
		set file [read $f]
		close $f
	    }] {
                continue
            }
            set file_lines [split $file "\n"]
	    
            set new_messages 1
            set end_of_headers_p 0
            set i 0
            set line [lindex $file_lines $i]
            set headers [list]
	    
            # walk through the headers and extract each one
            while ![empty_string_p $line] {
                set next_line [lindex $file_lines [expr $i + 1]]
                if {[regexp {^[ ]*$} $next_line match] && $i > 0} {
                    set end_of_headers_p 1
                }
                if {[regexp {^([^:]+):[ ]+(.+)$} $line match name value]} {
                    # concat header lines
                    if { ![regexp {^([^:]+):[ ]+(.+)$} $next_line match] && !$end_of_headers_p} {
			append line $next_line
			incr i
                    }
                    lappend headers [string tolower $name] $value
		    
                    if {$end_of_headers_p} {
			incr i
			break
                    }
                } else {
                    # The headers and the body are delimited by a null line as specified by RFC822
                    if {[regexp {^[ ]*$} $line match]} {
			incr i
			break
                    }
                }
                incr i
                set line [lindex $file_lines $i]
            }
            set body "\n[join [lrange $file_lines $i end] "\n"]"

	    ns_log Notice "im_mail_import.process_mails: mail_header='[join $headers "' '"]'"

            # Extract headers values
            array set email_headers $headers
	    set from_header ""
	    set to_header ""
	    set subject_header "No Subject"
            catch {set from_header $email_headers(from)}
            catch {set to_header $email_headers(to)}
            catch {set subject_header $email_headers(subject)}

	    set spam_header ""
	    if {[info exists email_headers(x-spambayes-classification)]} {

# Temporarily disabled spam - until
# Spambayes is trained correctly.
#
#		set spam_header $email_headers(x-spambayes-classification)
		ns_log Notice "im_mail_import.process_mails: spam_header=$spam_header"
	    } else {
		ns_log Notice "im_mail_import.process_mails: No spam header found"
	    }

	    set rfc822_message_id ""
	    if {[info exists email_headers(message-id)]} {
		set rfc822_message_id $email_headers(message-id)
		# remove the <...> brackets
		if {[regexp {\<([^\>]*)\>} $rfc822_message_id match id]} {
		    set rfc822_message_id $id
		}
		ns_log Notice "im_mail_import.process_mails: message-id=$rfc822_message_id"
	    } else {
		ns_log Notice "im_mail_import.process_mails: No message_id found"
	    }

            ns_log Notice "im_mail_import.process_mails: from_header=$from_header"
            ns_log Notice "im_mail_import.process_mails: to_header=$to_header"
            ns_log Notice "im_mail_import.process_mails: subject_header=$subject_header"
            ns_log Notice "im_mail_import.process_mails: rfc822_message_id=$rfc822_message_id"

	    # Move to "/spam" if there is a Spambayes header...
            if {[string equal "spam" $spam_header] } {
                if {[catch {
                    ns_log Notice "im_mail_import.process_mails: Moving '$msg' to spam: '$spam_folder/$msg_body'"
                    append debug "Moving '$msg' to spam: '$spam_folder/$msg_body'\n"
                    ns_rename $msg "$spam_folder/$msg_body"
                } errmsg]} {
                    ns_log Notice "im_mail_import.process_mails: Error moving '$msg' to spam: '$spam_folder/$msg_body': '$errmsg'"
                    append debug "Error moving '$msg' to spam: '$spam_folder/$msg_body': '$errmsg'\n"
                }
		continue
            }

	    # The the list of emails from the To and From fields
	    set to_emails [extract_emails $to_header]
	    set from_emails [extract_emails $from_header]

	    # Map the emails to user IDs. Use zero_ids to make sure
	    # that the list isn't empty.
	    set to_ids [map_emails_to_ids $to_emails]
	    set from_ids [map_emails_to_ids $from_emails]

	    # List of all ids: set to [list 0] if empty to avoid
	    # syntax errors in SQL
	    set all_ids [set_union $to_ids $from_ids]

	    # Calculate the IDs of non-Employees (=> external persons)
	    set employee_ids [db_list employee_ids "select member_id from group_distinct_member_map where group_id=[im_profile_employees]"]
	    set non_emp_ids [set_difference $all_ids $employee_ids]

	    # Move to "defered" if there is no employee right now...
            if {0 == [llength $non_emp_ids]} {
                if {[catch {
                    ns_log Notice "im_mail_import.process_mails: Moving '$msg' to defered: '$defered_folder/$msg_body'"
                    append debug "Moving '$msg' to defered: '$defered_folder/$msg_body'\n"
                    ns_rename $msg "$defered_folder/$msg_body"
                } errmsg]} {
                    ns_log Notice "im_mail_import.process_mails: Error moving '$msg' to defered: '$defered_folder/$msg_body': '$errmsg'"
                    append debug "Error moving '$msg' to defered: '$defered_folder/$msg_body': '$errmsg'\n"
                }
		continue
            }

	    # Create an OpenACS object with the mail
	    # 
	    set cr_item_id ""
	    set subject $subject_header
	    set html ""
	    set plain $body
	    set context_id ""
	    set user_id [ad_get_user_id]
	    set peeraddr [ad_conn peeraddr]
	    set approved_p 1
	    set send_date [db_string now "select now() from dual"]
	    set header_from $from_header
	    set header_to $to_header
	    set rfc822_id $rfc822_message_id
	    ns_log Notice "im_mail_import.process_mails: rfc822_id='$rfc822_id'"
	    append debug "rfc822_id='$rfc822_id'\n"

	    catch {
		set cr_item_id [db_exec_plsql im_mail_import_new_message {}]
		ns_log Notice "im_mail_import.process_mails: created spam_item \#$cr_item_id"
		append debug "created spam_item \#$cr_item_id\n"

		foreach non_emp_id $non_emp_ids {
		    set rel_type "im_mail_from"
		    set object_id_two $non_emp_id
		    set object_id_one $cr_item_id
		    set creation_user $user_id
		    set creation_ip $peeraddr
		    set rel_id [db_exec_plsql im_mail_import_new_rel {}]
		    ns_log Notice "im_mail_import.process_mails: created relationship \#$rel_id"
		    append debug "created relationship \#$rel_id\n"
		}
	    }

	    # Move to "processed" 
	    if {[catch {
		ns_log Notice "im_mail_import.process_mails: Moving '$msg' to processed: '$processed_folder/$msg_body'"
		append debug "Moving '$msg' to processed: '$processed_folder/$msg_body'\n"
		ns_rename $msg "$processed_folder/$msg_body"
	    } errmsg]} {
		ns_log Notice "im_mail_import.process_mails: Error moving '$msg' to processed: '$processed_folder/$msg_body': '$errmsg'"
		append debug "Error moving '$msg' to processes: '$processed_folder/$msg_body': '$errmsg'\n"
	    }
	}
	return $debug
    }
    
    ad_proc -public scan_mails {} {
        Scheduled procedure that will scan for bounced mails
    } {
	# SemP: Only allow one process to process...
	if {[nsv_incr im_mail_import check_mails_p] > 1} {
	    nsv_incr im_mail_import check_mails_p -1
	    return
	}
	
	catch {
	    ns_log Notice "im_mail_import.scan_mails: about to load qmail queue"
	    process_mails -mail_dir [mail_dir]
	} err_msg

	# SemV: Release Semaphore
	nsv_incr im_mail_import check_mails_p -1
    }


    ad_proc -private after_install {} {
        Callback to be called after package installation.
    } {
	# nothing
    }

    ad_proc -private before_uninstall {} {
        Callback to be called before package uninstallation.
    } {
	# nothing
    }

}


ad_proc im_mail_import_user_component {
    {-view_name ""}
    {-forum_order_by "priority"}
    {-rel_user_id 0}
} {
    Show a list of imported mails
} {
    set bgcolor(0) " class=roweven"
    set bgcolor(1) " class=rowodd"

    if {0 == $rel_user_id} {
	set rel_user_id [ad_get_user_id]
    }

    set html "
<table>
<tr class=rowtitle>
   <td class=rowtitle align=center colspan=99>Associated Emails</td>
</tr>
<tr class=rowtitle>
   <td class=rowtitle align=center>Date</td>
   <td class=rowtitle align=center>Subject</td>
   <td class=rowtitle align=center>From</td>
   <td class=rowtitle align=center>To</td>
</tr>
"

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
		and ar.object_id_two = :rel_user_id
    "

    set ctr 0
    db_foreach mail_list $sql {

	append html "
<tr $bgcolor([expr $ctr%2])>
   <td>$date_formatted</td>
   <td><a href=\"/intranet-mail-import/view?body_id=$body_id\">
     [string_truncate -len 50 $header_subject]
  </a></td>
   <td>[string_truncate -len 25 $header_from]</td>
   <td>[string_truncate -len 25 $header_to]</td>

</tr>
"
	incr ctr
    }

    if {0 == $ctr} {
	append html "
<tr $bgcolor([expr $ctr%2])>
   <td colspan=99 align=center>No entries found</td>
</tr>
"
    }

    append html "
</table>
"

    return $html
}

