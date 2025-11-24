#!/usr/bin/env python3
import json
import argparse
import sys
import os
import re

def process_dict_children(node, current_path, depth, target_path, prefix):
    keys = list(node.keys())
    
    # Grouping Logic
    groups = {} # Key: (num_pipes, num_dashes, separator, child_keys) -> Value: [list of keys]
    non_grouped_keys = []
    
    # Identify next step in target path to avoid hiding it in a group
    next_target_key = None
    if target_path and len(target_path) > len(current_path):
        next_target_key = target_path[len(current_path)]

    for key in keys:
        # Check if this key is the next step in target path
        if key == next_target_key:
            non_grouped_keys.append(key)
            continue

        is_candidate = False
        if isinstance(key, str):
            if isinstance(node[key], dict):
                is_candidate = True
        
        if is_candidate:
            # Count valid pipes: (?<=\S)\|(?=\S)
            valid_pipes = len(re.findall(r'(?<=\S)\|(?=\S)', key))
            
            num_pipes = 0
            num_dashes = 0
            separator = None
            
            if valid_pipes > 0:
                num_pipes = valid_pipes
                separator = '|'
            else:
                # Count valid dashes: (?<=\S)\-(?=\S)
                valid_dashes = len(re.findall(r'(?<=\S)\-(?=\S)', key))
                if valid_dashes > 0:
                    num_dashes = valid_dashes
                    separator = '-'
            
            child_keys = frozenset(node[key].keys())
            # Group ID: (num_pipes, num_dashes, separator, child_keys)
            group_id = (num_pipes, num_dashes, separator, child_keys)
            
            if group_id not in groups:
                groups[group_id] = []
            groups[group_id].append(key)
        else:
            non_grouped_keys.append(key)
    
    # Process groups: if a group has only 1 item, move it to non_grouped_keys
    final_groups = {}
    for group_id, group_keys in groups.items():
        if len(group_keys) > 1:
            final_groups[group_id] = group_keys
        else:
            non_grouped_keys.extend(group_keys)
    
    all_items_to_process = []
    
    # Add non-grouped
    for k in non_grouped_keys:
        all_items_to_process.append({'type': 'single', 'key': k})
        
    # Add groups
    for group_id, group_keys in final_groups.items():
        all_items_to_process.append({'type': 'group', 'keys': group_keys, 'id': group_id})
        
    # Sort by string representation
    all_items_to_process.sort(key=lambda x: str(x['key']) if x['type'] == 'single' else str(x['keys'][0]))

    for i, item in enumerate(all_items_to_process):
        is_last_child = (i == len(all_items_to_process) - 1)
        
        if item['type'] == 'single':
            key = item['key']
            print_tree(node[key], current_path + [key], depth + 1, target_path, is_last_child, prefix)
        else:
            # Print group representative
            group_keys = item['keys']
            first_key = group_keys[0]
            num_pipes = item['id'][0]
            num_dashes = item['id'][1]
            separator = item['id'][2]
            
            # Construct label: "<fld1>|<fld2>..."
            if separator:
                count = num_pipes if separator == '|' else num_dashes
                fields = ["<fld{}>".format(j+1) for j in range(count + 1)]
                label_pattern = separator.join(fields)
            else:
                # No separator (e.g. simple keys grouped by structure)
                label_pattern = "<fld1>"
            
            group_label = f'"{label_pattern}" (ex.: "{first_key}")'
            
            connector = "+--- " if is_last_child else "+--- "
            print(f"{prefix}{connector}{group_label}")
            
            # Recurse on the first key as representative
            # We need to adjust the prefix for the child
            grand_child_prefix = prefix
            if is_last_child:
                grand_child_prefix += "    "
            else:
                grand_child_prefix += "|   "

            representative_node = node[first_key]
            
            # Recursively process the children of the representative node
            # using the same grouping logic
            if isinstance(representative_node, dict):
                process_dict_children(representative_node, current_path + [first_key], depth + 1, target_path, grand_child_prefix)
            elif isinstance(representative_node, list):
                 # Should not happen based on grouping criteria (value is dict), but for safety
                 # If it were a list, we would need to handle it like print_tree handles lists
                 # But our grouping logic ensures value is dict.
                 pass

def print_tree(node, current_path=None, depth=0, target_path=None, is_last=True, prefix=""):
    if current_path == None:
        current_path = []
    
    # Determine if we are on the target path
    on_target_path = True
    if target_path:
        # Check if current_path matches the beginning of target_path
        if len(current_path) > len(target_path):
             on_target_path = False
        else:
             for i in range(len(current_path)):
                 if current_path[i] != target_path[i]:
                     on_target_path = False
                     break

    # Prepare the node label
    node_label = ""
    if depth == 0:
        node_label = "[root]"
    else:
        key = current_path[-1]
        if isinstance(key, int):
            node_label = f"[{key}]"
        else:
            node_label = str(key)

    # Highlight if this is the exact target
    if target_path and current_path == target_path:
        node_label += " <--- TARGET"

    # Print the current node
    connector = ""
    if depth > 0:
        connector = "+--- " if is_last else "+--- "
    
    print(f"{prefix}{connector}{node_label}")

    # Prepare prefix for children
    child_prefix = prefix
    if depth > 0:
        child_prefix += "    " if is_last else "|   "
    else:
        child_prefix = "     "

    # Recurse
    if isinstance(node, dict):
        process_dict_children(node, current_path, depth, target_path, child_prefix)

    elif isinstance(node, list):
        if not node:
            return

        # If we are on the target path and the next step is an index in this array, follow it.
        # Otherwise, default to index 0.
        
        indices_to_visit = []
        
        next_target_index = -1
        if target_path and len(target_path) > len(current_path):
             # Check if the next item in target_path is an integer (index)
             next_step = target_path[len(current_path)]
             if isinstance(next_step, int):
                 next_target_index = next_step

        if next_target_index != -1:
            if 0 <= next_target_index < len(node):
                indices_to_visit.append(next_target_index)
            else:
                # Index out of bounds, maybe just show 0?
                indices_to_visit.append(0)
        else:
            # Default to index 0
            indices_to_visit.append(0)
            
        for i, index in enumerate(indices_to_visit):
            is_last_child = (i == len(indices_to_visit) - 1)
            print_tree(node[index], current_path + [index], depth + 1, target_path, is_last_child, child_prefix)

def main():
    parser = argparse.ArgumentParser(description="Visualize JSON structure as an ASCII tree. Test it with: 'bin/json_tree_viewer.py crawler/test/test_grouping.json'")
    parser.add_argument("file_path", help="Path to the JSON file")
    parser.add_argument("--path", help="JSON string representing the path to follow (e.g., '[\"sections\", 22]')", default=None)

    args = parser.parse_args()

    try:
        with open(args.file_path, 'r') as f:
            data = json.load(f)
    except Exception as e:
        print(f"Error loading JSON file: {e}", file=sys.stderr)
        sys.exit(1)

    target_path = None
    if args.path:
        try:
            target_path = json.loads(args.path)
            if not isinstance(target_path, list):
                raise ValueError("Path must be a JSON list")
        except Exception as e:
            print(f"Error parsing path: {e}", file=sys.stderr)
            sys.exit(1)

    print_tree(data, target_path=target_path)

if __name__ == "__main__":
    main()
