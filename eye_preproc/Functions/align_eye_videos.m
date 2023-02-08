%% Align eyetracking data to videos
function align_eye_videos(options)
    
    %% Define directories    
    if exist(options.lum_dir, 'dir') == 0, mkdir(options.lum_dir), end
    
    options.fig_dir = sprintf('%s/Figures/video_alignment', options.code_dir);
    if exist(options.fig_dir, 'dir') == 0, mkdir(options.fig_dir), end
    
    options.res_dir = sprintf('%s/Results/video_alignment', options.code_dir);
    if exist(options.res_dir, 'dir') == 0, mkdir(options.res_dir), end
    
    % Get all subject labels
    [subs, sessions] = list_sub_ses(options.preproc_dir);
    
    % Read file order table
    file_order = readtable('file_order.xlsx');
    
    %% Compute movie metadata
    vid_meta_file = sprintf('%s/vid_metadata.mat', options.res_dir);
    
    if exist(vid_meta_file, 'file') == 0
    
        vid_files = dir(options.vid_dir);
        vid_files([vid_files.isdir]) = [];
        
        vid_fr = nan(1, length(vid_files));
        vid_T = nan(1, length(vid_files));
        vid_nfr = nan(1, length(vid_files));
        
        for v = 1:length(vid_files)
            vid = VideoReader(sprintf('%s/%s', options.vid_dir, vid_files(v).name));
            vid_fr(v) = vid.FrameRate;
            vid_T(v) = vid.Duration;
            vid_nfr(v) = vid.NumFrames;
        end
        
        vid_names = {vid_files.name};
        
        save(vid_meta_file, 'vid_fr', 'vid_T', 'vid_names', 'vid_nfr')
    
    else
        load(vid_meta_file, 'vid_fr', 'vid_T', 'vid_names', 'vid_nfr')
    end
    
    %% Align movie and eyetracking data and downsample
    
    % Table for length of eyetracking recordings
    et_vids_length = table;
    et_vids_column = file_order.label;
    
    file_names = {};
    
    res_file = sprintf('%s/et_vids_length.mat', options.res_dir);
    
    if exist(res_file, 'file') == 0
    
        for sub = 1:length(subs)
            for ses = 1:length(sessions{sub})
        
                % Read all recordings
                sub_dir = sprintf('%s/%s/%s/%s', options.preproc_dir, subs(sub).name, sessions{sub}{ses}, options.eye_dir);

                files = dir(sub_dir);
                files = files(cellfun(@(C) contains(C, sprintf('%s.json', options.eye_file_label)), {files.name}));
        
                et_vids_row = nan(1, length(et_vids_column));
    
                for f = 1:length(files)
        
                    fprintf('Aligning %s ...\n', files(f).name)
                    
                    % Load the data
                    % Metadata
                    metadata = load_et_bids_metadata(sub_dir, files(f).name);

                    % Data
                    et_data = load_et_bids_data(sub_dir, strrep(files(f).name, '.json', '.tsv.gz'));
        
                    % Time axis
                    et_time = table2array(et_data(:, ismember(metadata.Columns, 'Time')));

                    % Task start and end triggers
                    trigger_task = find(table2array(et_data(:, ismember(metadata.Columns, 'Task_Start_End_Trigger'))));
                    trigger_task_on = trigger_task(1);
                    trigger_task_off = trigger_task(2);

                    % Total time of recording
                    time_eye = et_time(trigger_task_off) - et_time(trigger_task_on);
        
                    % Get the order of the file
                    idx_order = cellfun(@(C) contains(files(f).name, C), file_order.bids_name);
        
                    et_vids_row(idx_order) = time_eye;

                    %% Downsample
                    % Find the corresponding video
                    vid_rec = file_order.vid_name{cellfun(@(C) contains(files(f).name, C), file_order.bids_name)};
                    idx_vid = ismember(vid_names, vid_rec);
    
                    if sum(idx_vid) == 0 && ~contains(files(f).name, 'rest')
                        continue
                    end
    
                    % Cut data at triggers
                    et_data = et_data(trigger_task_on+1:trigger_task_off, :);

                    % Compute difference between the time of the recording and the video to adjust for delays
                    if sum(idx_vid) == 0 
                        metadata.TimeDifferenceEyetrackingVideo = time_eye - options.rest_time;
                    else
                        if contains(vid_names{idx_vid}, 'Monkey')
                            metadata.TimeDifferenceEyetrackingVideo = time_eye - options.monkey_time;
                        else
                            metadata.TimeDifferenceEyetrackingVideo = time_eye - vid_T(idx_vid);
                        end
                    end
    
                    % In many recordings of incapes the videoplayback is delayed
                    if contains(files(f).name, 'inscapes') && metadata.TimeDifferenceEyetrackingVideo > options.time_diff_thresh
                        offset = height(et_data) - (vid_T(idx_vid) * metadata.SamplingFrequency);
                        et_data = et_data(offset+1:end, :); 
                    end
    
                    % Split eyetracking and event data
                    idx_time = ismember(metadata.Columns, 'Time');
                    et_time = table2array(et_data(:, idx_time));
                    col_time = metadata.Columns(:, idx_time);

                    idx_events = ismember(metadata.Columns, {'Fixations', 'Saccades', 'Blinks', 'fMRI_Volume_Trigger', 'Interpolated_Samples'});
                    et_events = table2array(et_data(:, idx_events));
                    col_events = metadata.Columns(:, idx_events);

                    idx_data = cellfun(@(C) contains(C, {'Gaze', 'Pupil', 'Resolution'}), metadata.Columns);
                    et_data = table2array(et_data(:, idx_data));
                    col_data = metadata.Columns(:, idx_data);

                    metadata.Columns = col_data;

                    % Get downsampling factor 
                    if sum(idx_vid) == 0 
                        dsf = options.rest_fs / metadata.SamplingFrequency;
                    else
                        if contains(vid_names{idx_vid}, 'Monkey')
                            dsf = (options.monkey_time/vid_T(idx_vid) * vid_nfr(idx_vid)) / length(et_data);
                        else
                            dsf = vid_nfr(idx_vid) / length(et_data);
                        end
                    end
    
                    % Downsample
                    if dsf*1e10 < 2^31
                        et_data = resample(et_data - et_data(1,:), round(1e5*dsf), 1e5) + et_data(1,:);
                    else
                        et_data = resample(et_data - et_data(1,:), round(1e5*dsf), 1e4) + et_data(1,:);
                    end

                    % Add time
                    et_data = [linspace(et_time(1), et_time(end), length(et_data))', et_data];
    
                    metadata.Columns = [col_time, metadata.Columns];

                    %% Update metadata
                    metadata.SamplingFrequency = vid_fr(idx_vid);
    
                    % Interpolate time of triggers
                    et_events_rs = zeros(length(et_data), length(col_events));

                    for e = 1:length(col_events)

                        idx_event = ismember(col_events, col_events{e});

                        events = et_events(:, idx_event);
    
                        if contains(col_events{e}, 'Trigger')
                            et_events_rs(round(interp1(et_data(:,1), 1:length(et_data), et_time(events == 1))), ...
                                idx_event) = 1;
                        else
    
                            [labeled_events] = bwlabel(events);
                            props = regionprops(labeled_events, 'Area', 'PixelList');
            
                            event_onset = cellfun(@(C) min(C(:,2)), {props.PixelList});
                            event_offset = cellfun(@(C) max(C(:,2)), {props.PixelList});
        
                            event_rs = round(interp1(et_data(:,1), 1:length(et_data), et_time([event_onset', event_offset'])));
        
                            for i = 1:size(event_rs,1)
                                et_events_rs(event_rs(i,1):event_rs(i,2), idx_event) = 1;
                            end

                        end

                    end

                    % Combine data
                    et_data = [et_data, et_events_rs];
                    metadata.Columns = [metadata.Columns, col_events];
        
                    %% Save the data

                    % Edit label 
                    eye_file_parts = strsplit(options.eye_file_label, '_');
                    eye_file_parts(cellfun(@(C) isempty(C), eye_file_parts)) = [];

                    out_file_label = sprintf('_%s_video_aligned_%s', eye_file_parts{1}, eye_file_parts{2});
                    out_file_json = strrep(files(f).name, options.eye_file_label, out_file_label);

                    % Remove description for removed columns
                    metadata = rmfield(metadata, 'Task_Start_End_Trigger');
                    metadata = rmfield(metadata, 'Timer_Trigger_1_second');
                      
                    % Metadata
                    save_et_bids_metadata(metadata, sub_dir, out_file_json)

                    % Data
                    save_et_bids_data(et_data, sub_dir, strrep(out_file_json, '.json', '.tsv'))
       
                end
    
                row = array2table(et_vids_row, 'VariableNames', et_vids_column);

                et_vids_length = [et_vids_length; row];

                file_names = [file_names; sprintf('%s_%s', subs(sub).name, sessions{sub}{ses})];
        
            end
        end
        
        et_vids_length = [table(file_names, 'VariableNames', {'sub_ses'}), et_vids_length];
        
        save(res_file, 'et_vids_length')
        
        % Combine data for plot
        unique_vids = unique(file_order.name);
        
        for vid = 1:length(unique_vids)
            
            idx_vid = find(ismember(file_order.name, unique_vids(vid)));
        
            length_vid = [];
        
            for i = 1:length(idx_vid) 
                idx_dat = cellfun(@(C) contains(file_order.label(idx_vid(i)), C), et_vids_length.Properties.VariableNames);
                length_vid = [length_vid; table2array(et_vids_length(:,idx_dat))];
            end
        
            figure
            histogram(length_vid, 50)
        
            title(strrep(unique_vids{vid}, '_', ' '))
            xlabel('Time [s]')
            ylabel('Number of recordings')
            set(gca, 'FontSize', 12)
        
            grid on, grid minor
        
            saveas(gca, sprintf('%s/%s_video_recording_length.png', options.fig_dir, unique_vids{vid}))
        
            close all
        
        end
    
    end

end